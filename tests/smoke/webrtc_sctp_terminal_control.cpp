#include "sctptransport.hpp"
#include "rtc/global.hpp"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <vector>

namespace {
std::mutex gate;
std::condition_variable ready;
std::thread::id notificationThread;
int pauseAt = -1;
bool paused = false;
bool released = false;
bool lowerEntered = false;
std::atomic<int> errors{0};
}

void sf_terminal_hook(int point) {
    std::unique_lock lock(gate);
    if (point == 3 && std::this_thread::get_id() != notificationThread) {
        lowerEntered = true;
        ready.notify_all();
    }
    if (point != pauseAt || std::this_thread::get_id() != notificationThread)
        return;
    paused = true;
    ready.notify_all();
    if (!ready.wait_for(lock, std::chrono::seconds(5), [] { return released; }))
        throw std::runtime_error("terminal control release timed out");
}

namespace rtc::impl {
struct SctpTerminalControl {
    using State = Transport::State;

    static void run(const char *name, State initial, int notifications, int lowerFirst,
                    int pausePoint, bool lateUp, bool expectedFailure, bool reentrant = false) {
        std::atomic<int> ended{0};
        std::mutex statesMutex;
        std::vector<State> states;
        std::shared_ptr<SctpTransport> peer;
        peer = std::make_shared<SctpTransport>(
            nullptr, Configuration{}, SctpTransport::Ports{},
            [&](message_ptr p) { if (!p) ++ended; }, nullptr,
            [&](State s) {
                {
                    std::lock_guard lock(statesMutex);
                    states.push_back(s);
                }
                if (reentrant && s == State::Disconnected) {
                    peer->close();
                    peer->incoming(nullptr);
                }
            });
        peer->mWrittenOnce = true;
        peer->changeState(initial);
        states.clear();
        errors = 0;
        union sctp_notification notification{};
        auto &sac = notification.sn_assoc_change;
        sac.sac_type = SCTP_ASSOC_CHANGE;
        sac.sac_length = sizeof(sctp_assoc_change);
        sac.sac_state = SCTP_COMM_LOST;
        sac.sac_error = 12;
        sac.sac_assoc_id = 1;
        const auto notify = [&] {
            peer->processNotification(&notification, sizeof(sctp_assoc_change));
        };
        for (int i = 0; i < lowerFirst; ++i)
            peer->incoming(nullptr);
        if (pausePoint >= 0) {
            {
                std::lock_guard lock(gate);
                pauseAt = pausePoint;
                paused = released = false;
            }
            std::thread worker([&] {
                {
                    std::lock_guard lock(gate);
                    notificationThread = std::this_thread::get_id();
                }
                notify();
            });
            {
                std::unique_lock lock(gate);
                if (!ready.wait_for(lock, std::chrono::seconds(5), [] { return paused; })) {
                    released = true;
                    ready.notify_all();
                    lock.unlock();
                    worker.join();
                    throw std::runtime_error("terminal control pause timed out");
                }
            }
            peer->incoming(nullptr);
            {
                std::lock_guard lock(gate);
                released = true;
            }
            ready.notify_all();
            worker.join();
            pauseAt = -1;
            --notifications;
        }
        for (int i = 0; i < notifications; ++i)
            notify();
        if (lateUp) {
            sac.sac_state = SCTP_COMM_UP;
            peer->processNotification(&notification, sizeof(sctp_assoc_change));
        }
        const auto expected = expectedFailure ? State::Failed : State::Disconnected;
        const int expectedCallbacks = initial == expected ? 0 : 1;
        const int expectedEnded = expectedFailure || initial == State::Disconnected ? 0 : 1;
        const int expectedErrors = expectedFailure && initial != State::Failed ? 1 : 0;
        const bool passed = peer->state() == expected &&
            int(states.size()) == expectedCallbacks &&
            (states.empty() || states[0] == expected) && ended == expectedEnded &&
            errors == expectedErrors;
        std::cout << "{\"case\":\"" << name << "\",\"passed\":"
                  << (passed ? "true" : "false") << ",\"state\":" << int(peer->state())
                  << ",\"state_callbacks\":" << states.size()
                  << ",\"eof_callbacks\":" << ended << ",\"errors\":" << errors << "}"
                  << std::endl;
    }

    static void nullStateCallback(bool connecting) {
        std::atomic<int> ended{0};
        auto peer = std::make_shared<SctpTransport>(
            nullptr, Configuration{}, SctpTransport::Ports{},
            [&](message_ptr p) { if (!p) ++ended; }, nullptr, nullptr);
        peer->mWrittenOnce = true;
        peer->changeState(connecting ? State::Connecting : State::Connected);
        errors = 0;
        union sctp_notification notification{};
        auto &sac = notification.sn_assoc_change;
        sac.sac_type = SCTP_ASSOC_CHANGE;
        sac.sac_length = sizeof(sctp_assoc_change);
        sac.sac_state = SCTP_COMM_LOST;
        sac.sac_error = 12;
        sac.sac_assoc_id = 1;
        peer->processNotification(&notification, sizeof(sctp_assoc_change));
        peer->processNotification(&notification, sizeof(sctp_assoc_change));
        const bool passed = peer->state() == (connecting ? State::Failed : State::Disconnected) &&
            ended == (connecting ? 0 : 1) && errors == (connecting ? 1 : 0);
        std::cout << "{\"case\":\"null_state_callback" << (connecting ? "_failure" : "")
                  << "\",\"passed\":" << (passed ? "true" : "false")
                  << ",\"state\":" << int(peer->state())
                  << ",\"state_callbacks\":0,\"eof_callbacks\":" << ended
                  << ",\"errors\":" << errors << "}" << std::endl;
    }

    static void delayedConnectedCallback() {
        std::atomic<int> ended{0};
        std::mutex statesMutex;
        std::vector<State> states;
        auto peer = std::make_shared<SctpTransport>(
            nullptr, Configuration{}, SctpTransport::Ports{},
            [&](message_ptr p) { if (!p) ++ended; }, nullptr,
            [&](State s) { std::lock_guard lock(statesMutex); states.push_back(s); });
        peer->mWrittenOnce = true;
        peer->changeState(State::Connecting);
        states.clear();
        errors = 0;
        union sctp_notification notification{};
        auto &sac = notification.sn_assoc_change;
        sac.sac_type = SCTP_ASSOC_CHANGE;
        sac.sac_length = sizeof(sctp_assoc_change);
        sac.sac_state = SCTP_COMM_UP;
        {
            std::lock_guard lock(gate);
            pauseAt = 2;
            paused = released = lowerEntered = false;
        }
        std::thread worker([&] {
            {
                std::lock_guard lock(gate);
                notificationThread = std::this_thread::get_id();
            }
            peer->processNotification(&notification, sizeof(sctp_assoc_change));
        });
        {
            std::unique_lock lock(gate);
            if (!ready.wait_for(lock, std::chrono::seconds(5), [] { return paused; }))
                std::terminate();
        }
        std::thread lower([&] { peer->incoming(nullptr); });
        {
            std::unique_lock lock(gate);
            if (!ready.wait_for(lock, std::chrono::seconds(5), [] { return lowerEntered; }))
                std::terminate();
            released = true;
        }
        ready.notify_all();
        worker.join();
        lower.join();
        pauseAt = -1;
        const bool passed = peer->state() == State::Disconnected && ended == 1 && errors == 0 &&
            states == std::vector<State>{State::Connected, State::Disconnected};
        std::cout << "{\"case\":\"delayed_connected_callback\",\"passed\":"
                  << (passed ? "true" : "false") << ",\"state\":" << int(peer->state())
                  << ",\"state_callbacks\":" << states.size()
                  << ",\"eof_callbacks\":" << ended << ",\"errors\":" << errors << "}"
                  << std::endl;
    }

};
}

int main() {
    rtc::InitLogger(rtc::LogLevel::Error, [](rtc::LogLevel, std::string message) {
        if (message.find("SCTP connection failed") != std::string::npos)
            ++errors;
    });
    using Control = rtc::impl::SctpTerminalControl;
    using State = rtc::impl::Transport::State;
    Control::run("connecting_failure", State::Connecting, 1, false, -1, false, true);
    Control::run("connected_loss", State::Connected, 1, false, -1, false, false);
    Control::run("repeated_notification", State::Connected, 2, false, -1, false, false);
    Control::run("lower_before_notification", State::Connected, 1, true, -1, false, false);
    Control::run("lower_before_classification", State::Connected, 1, false, 0, false, false);
    Control::run("lower_after_selection", State::Connected, 1, false, 1, false, false);
    Control::run("late_comm_up", State::Connected, 1, false, -1, true, false);
    Control::run("failed_notification", State::Failed, 1, false, -1, false, true);
    Control::run("failed_lower", State::Failed, 0, true, -1, false, true);
    Control::run("duplicate_lower", State::Connected, 0, 2, -1, false, false);
    Control::run("disconnected_notification", State::Disconnected, 1, false, -1, false, false);
    Control::run("reentrant_disconnect", State::Connected, 1, false, -1, false, false, true);
    Control::delayedConnectedCallback();
    Control::nullStateCallback(false);
    Control::nullStateCallback(true);
}

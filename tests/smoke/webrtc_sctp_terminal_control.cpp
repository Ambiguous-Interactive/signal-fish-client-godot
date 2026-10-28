#include "sctptransport.hpp"
#include "rtc/global.hpp"

#include <atomic>
#include <chrono>
#include <cerrno>
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
std::atomic<int> shutdownErrno{0};
bool preInitWaiting = false;
bool cancelInitWaitEntered = false;
std::atomic<int> conninputCalls{0};
}

void sf_terminal_hook(int point) {
    if (point == 4) shutdownErrno = errno;
    if (point == 6) ++conninputCalls;
    std::unique_lock lock(gate);
    if (point == 8) {
        cancelInitWaitEntered = true;
        ready.notify_all();
    }
    if (point == 5) {
        preInitWaiting = true;
        ready.notify_all();
    }
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

    static std::mutex &writtenMutex(SctpTransport &peer) {
#ifdef SF_TERMINAL_REPAIRED
        return peer.mInitMutex;
#else
        return peer.mWriteMutex;
#endif
    }

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

    static void earlyClose(bool promote) {
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
        shutdownErrno = 0;
        if (promote) {
            {
                std::lock_guard lock(gate);
                pauseAt = 4;
                paused = released = false;
            }
            std::thread worker([&] {
                {
                    std::lock_guard lock(gate);
                    notificationThread = std::this_thread::get_id();
                }
                peer->close();
            });
            {
                std::unique_lock lock(gate);
                if (!ready.wait_for(lock, std::chrono::seconds(5), [] { return paused; }))
                    std::terminate();
            }
            union sctp_notification notification{};
            auto &sac = notification.sn_assoc_change;
            sac.sac_type = SCTP_ASSOC_CHANGE;
            sac.sac_length = sizeof(sctp_assoc_change);
            sac.sac_state = SCTP_COMM_UP;
            peer->processNotification(&notification, sizeof(sctp_assoc_change));
            {
                std::lock_guard lock(gate);
                released = true;
            }
            ready.notify_all();
            worker.join();
            pauseAt = -1;
        } else {
            peer->close();
        }
        const auto expected = promote ? State::Disconnected : State::Failed;
        const auto expectedStates = promote ? std::vector<State>{State::Connected, State::Disconnected}
                                            : std::vector<State>{State::Failed};
        const bool passed = peer->state() == expected && ended == (promote ? 1 : 0) &&
            errors == 0 && states == expectedStates && !peer->mSendQueue.running() &&
            shutdownErrno == ENOTCONN;
        std::cout << "{\"case\":\"" << (promote ? "close_during_comm_up" : "close_connecting")
                  << "\",\"passed\":" << (passed ? "true" : "false")
                  << ",\"state\":" << int(peer->state())
                  << ",\"state_callbacks\":" << states.size()
                  << ",\"eof_callbacks\":" << ended << ",\"errors\":" << errors
                  << ",\"send_queue_running\":" << (peer->mSendQueue.running() ? "true" : "false")
                  << ",\"shutdown_errno\":" << shutdownErrno << "}" << std::endl;
    }

    static void preInit(int action) {
        std::atomic<int> ended{0};
        std::atomic<bool> finished{false};
        std::vector<State> states;
        struct Lower : Transport {
            int writes = 0;
            bool send(message_ptr message) override {
                ++writes;
                return message && message->size() == 1;
            }
        };
        auto lower = std::make_shared<Lower>();
        std::shared_ptr<SctpTransport> peer;
        peer = std::make_shared<SctpTransport>(
            lower, Configuration{}, SctpTransport::Ports{},
            [&](message_ptr p) { if (!p) ++ended; }, nullptr,
            [&](State s) {
                states.push_back(s);
                if (action == 4 && s == State::Failed) peer->incoming(make_message(0));
            });
        peer->changeState(State::Connecting);
        states.clear();
        errors = 0;
        conninputCalls = 0;
        {
            std::lock_guard lock(gate);
            preInitWaiting = false;
        }
        std::thread worker([&] {
            peer->incoming(action == 0 || action == 4 ? nullptr : make_message(0));
            std::lock_guard lock(gate);
            finished = true;
            ready.notify_all();
        });
        {
            std::unique_lock lock(gate);
            if (!ready.wait_for(lock, std::chrono::seconds(5), [&] {
                return preInitWaiting || finished;
            })) std::terminate();
        }
        bool waiting = false;
        {
            std::lock_guard lock(writtenMutex(*peer));
            waiting = !finished;
        }
        if (action == 1) peer->close();
        if (action == 2) {
            union sctp_notification notification{};
            auto &sac = notification.sn_assoc_change;
            sac.sac_type = SCTP_ASSOC_CHANGE;
            sac.sac_length = sizeof(sctp_assoc_change);
            sac.sac_state = SCTP_CANT_STR_ASSOC;
            peer->processNotification(&notification, sizeof(sctp_assoc_change));
        }
        int writeError = 0;
        if (action == 3) {
            byte packet{};
            writeError = peer->handleWrite(&packet, 1, 0, 0);
        } else if ((action == 0 || action == 4) && waiting) {
            std::lock_guard lock(writtenMutex(*peer));
            peer->mWrittenOnce = true;
            peer->mWrittenCondition.notify_all();
        }
        {
            std::unique_lock lock(gate);
            if (!ready.wait_for(lock, std::chrono::seconds(5), [&] { return bool(finished); }))
                std::terminate();
        }
        worker.join();
        const auto expected = action == 3 ? State::Connecting : State::Failed;
        const auto expectedStates = action == 3 ? std::vector<State>{} : std::vector<State>{State::Failed};
        const bool passed = (action == 0 || action == 4 ? !waiting : waiting) &&
            peer->state() == expected && states == expectedStates && ended == 0 &&
            errors == (action == 0 || action == 2 || action == 4 ? 1 : 0) &&
            conninputCalls == (action == 3 ? 1 : 0) &&
            (action != 1 || !peer->mSendQueue.running()) &&
            writeError == 0 && lower->writes == (action == 3 ? 1 : 0);
        const char *names[] = {"preinit_lower_eof", "preinit_close", "preinit_failure", "preinit_local_write", "preinit_reentrant_eof"};
        std::cout << "{\"case\":\"" << names[action] << "\",\"passed\":"
                  << (passed ? "true" : "false") << ",\"state\":" << int(peer->state())
                  << ",\"state_callbacks\":" << states.size()
                  << ",\"eof_callbacks\":" << ended << ",\"errors\":" << errors
                  << ",\"waited_before_terminal\":" << (waiting ? "true" : "false")
                  << ",\"conninput_calls\":" << conninputCalls << "}" << std::endl;
    }

    static void preInitWaitRace(bool closing) {
        std::atomic<int> ended{0};
        std::atomic<bool> finished{false};
        bool terminalFinished = false;
        std::vector<State> states;
        auto peer = std::make_shared<SctpTransport>(
            nullptr, Configuration{}, SctpTransport::Ports{},
            [&](message_ptr p) { if (!p) ++ended; }, nullptr,
            [&](State s) { states.push_back(s); });
        peer->changeState(State::Connecting);
        states.clear();
        errors = 0;
        conninputCalls = 0;
        {
            std::lock_guard lock(gate);
            pauseAt = 5;
            paused = released = cancelInitWaitEntered = false;
        }
        std::thread reader([&] {
            {
                std::lock_guard lock(gate);
                notificationThread = std::this_thread::get_id();
            }
            peer->incoming(make_message(0));
            std::lock_guard lock(gate);
            finished = true;
            ready.notify_all();
        });
        {
            std::unique_lock lock(gate);
            if (!ready.wait_for(lock, std::chrono::seconds(5), [] { return paused; }))
                std::terminate();
        }
        std::thread terminal([&] {
            if (closing) peer->close();
            else {
                union sctp_notification notification{};
                auto &sac = notification.sn_assoc_change;
                sac.sac_type = SCTP_ASSOC_CHANGE;
                sac.sac_length = sizeof(sctp_assoc_change);
                sac.sac_state = SCTP_CANT_STR_ASSOC;
                peer->processNotification(&notification, sizeof(sctp_assoc_change));
            }
            std::lock_guard lock(gate);
            terminalFinished = true;
            ready.notify_all();
        });
        {
            std::unique_lock lock(gate);
            if (!ready.wait_for(lock, std::chrono::seconds(5), [&] {
#ifdef SF_TERMINAL_REPAIRED
                return cancelInitWaitEntered;
#else
                return terminalFinished;
#endif
            })) std::terminate();
            released = true;
        }
        ready.notify_all();
        terminal.join();
        bool completed = false;
        {
            std::unique_lock lock(gate);
            completed = ready.wait_for(lock, std::chrono::seconds(5), [&] { return bool(finished); });
        }
        if (!completed) {
            std::lock_guard lock(writtenMutex(*peer));
            peer->mWrittenOnce = true;
            peer->mWrittenCondition.notify_all();
        }
        reader.join();
        pauseAt = -1;
        const bool passed = completed && peer->state() == State::Failed && ended == 0 &&
            errors == (closing ? 0 : 1) && conninputCalls == 0 &&
            states == std::vector<State>{State::Failed};
        std::cout << "{\"case\":\"preinit_" << (closing ? "close" : "failure")
                  << "_wait_race\",\"passed\":" << (passed ? "true" : "false")
                  << ",\"state\":" << int(peer->state())
                  << ",\"state_callbacks\":" << states.size()
                  << ",\"eof_callbacks\":" << ended << ",\"errors\":" << errors
                  << ",\"completed_without_rescue\":" << (completed ? "true" : "false")
                  << ",\"conninput_calls\":" << conninputCalls << "}" << std::endl;
    }

    static void startup(int action) {
        struct Lower : Transport {
            std::atomic<int> writes{0};
            bool send(message_ptr message) override { ++writes; return bool(message); }
            void receive(message_ptr message) { recv(message); }
        };
        auto lower = std::make_shared<Lower>();
        std::atomic<int> ended{0};
        std::atomic<bool> finished{false};
        std::vector<State> states;
        std::shared_ptr<SctpTransport> peer;
        peer = std::make_shared<SctpTransport>(
            lower, Configuration{}, SctpTransport::Ports{},
            [&](message_ptr p) { if (!p) ++ended; }, nullptr,
            [&](State s) {
                states.push_back(s);
                if (action == 3 && s == State::Connecting) peer->close();
            });
        if (action == 0) lower->receive(nullptr);
        if (action == 1) lower->receive(make_message(0));
        if (action == 2) peer->close();
        errors = 0;
        conninputCalls = 0;
        {
            std::lock_guard lock(gate);
            preInitWaiting = false;
        }
        std::thread worker([&] {
            peer->start();
            std::lock_guard lock(gate);
            finished = true;
            ready.notify_all();
        });
        {
            std::unique_lock lock(gate);
            if (!ready.wait_for(lock, std::chrono::seconds(5), [&] {
                return preInitWaiting || finished;
            })) std::terminate();
        }
        bool rescued = false;
        {
            std::lock_guard lock(writtenMutex(*peer));
            rescued = !finished;
            if (rescued) peer->mWrittenOnce = true;
        }
        if (rescued) peer->mWrittenCondition.notify_all();
        worker.join();
        const auto expected = action == 1 ? State::Connecting : action == 2 ? State::Disconnected : State::Failed;
        const auto expectedStates = action == 1 ? std::vector<State>{State::Connecting} :
            action == 2 ? std::vector<State>{} : std::vector<State>{State::Connecting, State::Failed};
        const bool passed = !rescued && peer->state() == expected && states == expectedStates &&
            ended == 0 && errors == (action == 0 ? 1 : 0) && conninputCalls == (action == 1 ? 1 : 0) &&
            lower->writes == (action <= 1 ? 1 : 0);
        const char *names[] = {"startup_buffered_eof", "startup_buffered_data", "startup_after_close", "startup_reentrant_close"};
        std::cout << "{\"case\":\"" << names[action] << "\",\"passed\":"
                  << (passed ? "true" : "false") << ",\"state\":" << int(peer->state())
                  << ",\"state_callbacks\":" << states.size()
                  << ",\"eof_callbacks\":" << ended << ",\"errors\":" << errors
                  << ",\"rescued\":" << (rescued ? "true" : "false")
                  << ",\"local_writes\":" << lower->writes << "}" << std::endl;
        peer->onStateChange(nullptr);
        peer->close();
    }

    static void startupCloseRace(int point) {
        struct Lower : Transport {
            std::atomic<int> writes{0};
            bool send(message_ptr message) override { ++writes; return bool(message); }
        };
        auto lower = std::make_shared<Lower>();
        std::atomic<int> ended{0};
        std::vector<State> states;
        auto peer = std::make_shared<SctpTransport>(
            lower, Configuration{}, SctpTransport::Ports{},
            [&](message_ptr p) { if (!p) ++ended; }, nullptr,
            [&](State s) { states.push_back(s); });
        errors = 0;
        {
            std::lock_guard lock(gate);
            pauseAt = point;
            paused = released = false;
        }
        std::thread worker([&] {
            {
                std::lock_guard lock(gate);
                notificationThread = std::this_thread::get_id();
            }
            peer->start();
        });
        {
            std::unique_lock lock(gate);
            if (!ready.wait_for(lock, std::chrono::seconds(5), [] { return paused; }))
                std::terminate();
        }
        peer->close();
        {
            std::lock_guard lock(gate);
            released = true;
        }
        ready.notify_all();
        worker.join();
        pauseAt = -1;
        const bool passed = peer->state() == State::Failed && errors == 0 && ended == 0 &&
            lower->writes == 0 && states == std::vector<State>{State::Connecting, State::Failed};
        std::cout << "{\"case\":\"startup_close_before_" << (point == 9 ? "transition" : "bind")
                  << "\",\"passed\":" << (passed ? "true" : "false")
                  << ",\"state\":" << int(peer->state())
                  << ",\"state_callbacks\":" << states.size()
                  << ",\"eof_callbacks\":" << ended << ",\"errors\":" << errors
                  << ",\"local_writes\":" << lower->writes << "}" << std::endl;
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
    Control::earlyClose(false);
    Control::earlyClose(true);
    for (int action = 0; action != 5; ++action) Control::preInit(action);
    Control::preInitWaitRace(true);
    Control::preInitWaitRace(false);
    for (int action = 0; action != 4; ++action) Control::startup(action);
    Control::startupCloseRace(9);
    Control::startupCloseRace(10);
}

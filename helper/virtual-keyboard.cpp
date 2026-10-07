// TypeThru Virtual Keyboard. Local, single-user HID bridge; never reads the clipboard.
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstring>
#include <iostream>
#include <poll.h>
#include <spawn.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
#include <pqrs/karabiner/driverkit/virtual_hid_device_service.hpp>
extern char** environ;
namespace dk = pqrs::karabiner::driverkit;
using namespace std::chrono_literals;
volatile sig_atomic_t stopping = 0;
constexpr auto socketPath = "/var/run/io.github.sayre4ux.typethru.virtual-keyboard.sock";
constexpr auto daemonPath = "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon";

bool valid(const uint8_t* p) {
    if (p[0] != 1) return false;
    if (p[1] == 0) return true; // readiness probe
    unsigned hold = p[4] | (p[5] << 8), gap = p[6] | (p[7] << 8);
    return p[1] == 1 && ((p[2] >= 4 && p[2] <= 56) || p[2] == 100)
        && (p[3] == 0 || p[3] == 2) && hold >= 10 && hold <= 200 && gap <= 500;
}
int connectSocket(const char* path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    sockaddr_un address{}; address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    if (connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
        close(fd); return -1;
    }
    return fd;
}
int main(int argc, char** argv) {
    if (argc == 2 && std::string(argv[1]) == "--check-protocol") {
        const uint8_t good[] = {1,1,4,2,80,0,120,0};
        uint8_t bad[8]; memcpy(bad, good, 8); bad[2] = 0xff;
        if (!valid(good) || valid(bad)) return 1;
        memcpy(bad, good, 8); bad[3] = 8; if (valid(bad)) return 1;
        memcpy(bad, good, 8); bad[4] = 0; if (valid(bad)) return 1;
        std::cout << "TypeThru Virtual Keyboard protocol checks passed (no input sent).\n";
        return 0;
    }
    if (argc != 2 || geteuid() != 0) return 2;
    char* end = nullptr;
    auto uidValue = strtoul(argv[1], &end, 10);
    if (!end || *end || uidValue < 501 || uidValue >= UINT32_MAX) return 2;
    uid_t allowedUID = static_cast<uid_t>(uidValue);
    signal(SIGTERM, [](int) { stopping = 1; });
    signal(SIGINT, [](int) { stopping = 1; });
    signal(SIGPIPE, SIG_IGN);
    pid_t ownedDaemon = 0;
    auto driverSocket = dk::virtual_hid_device_service::constants::get_server_socket_file_path().string();
    int existing = connectSocket(driverSocket.c_str());
    if (existing >= 0) close(existing);
    else {
        char* args[] = {const_cast<char*>(daemonPath), nullptr};
        if (posix_spawn(&ownedDaemon, daemonPath, nullptr, nullptr, args, environ) != 0) return 3;
    }
    int server = socket(AF_UNIX, SOCK_STREAM, 0);
    sockaddr_un address{}; address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, socketPath, sizeof(address.sun_path));
    unlink(socketPath); umask(0077);
    if (server < 0 || bind(server, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0
        || chown(socketPath, allowedUID, 0) != 0 || chmod(socketPath, 0600) != 0 || listen(server, 4) != 0) {
        if (ownedDaemon > 0) kill(ownedDaemon, SIGTERM);
        return 4;
    }
    pqrs::dispatcher::extra::initialize_shared_dispatcher();
    {
        std::atomic<bool> ready{false};
        auto client = std::make_unique<dk::virtual_hid_device_service::client>();
        client->connected.connect([&] {
            dk::virtual_hid_device_service::virtual_hid_keyboard_parameters params;
            params.set_country_code(pqrs::hid::country_code::us);
            client->async_virtual_hid_keyboard_initialize(params);
        });
        client->virtual_hid_keyboard_ready.connect([&](bool value) { ready = value; });
        client->closed.connect([&] { ready = false; });
        client->async_start();
        auto release = [&] { client->async_post_report(dk::virtual_hid_device_driver::hid_report::keyboard_input{}); };
        while (!stopping) {
            pollfd pending{server, POLLIN, 0};
            if (poll(&pending, 1, 250) <= 0) continue;
            int fd = accept(server, nullptr, nullptr);
            if (fd < 0) continue;
            uid_t peer; gid_t group;
            if (getpeereid(fd, &peer, &group) != 0 || peer != allowedUID) { close(fd); continue; }
            timeval timeout{2, 0};
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
            uint8_t packet[8]{};
            ssize_t received = recv(fd, packet, sizeof(packet), MSG_WAITALL);
            uint8_t response = 2;
            if (received == 8 && valid(packet)) {
                response = ready ? 0 : 1;
                if (ready && packet[1] == 1 && !stopping) {
                    dk::virtual_hid_device_driver::hid_report::keyboard_input report;
                    if (packet[3] == 2) {
                        report.modifiers.insert(dk::virtual_hid_device_driver::hid_report::modifier::left_shift);
                        client->async_post_report(report);
                        std::this_thread::sleep_for(20ms);
                    }
                    report.keys.insert(packet[2]);
                    client->async_post_report(report);
                    std::this_thread::sleep_for(std::chrono::milliseconds(packet[4] | (packet[5] << 8)));
                    release();
                    std::this_thread::sleep_for(std::chrono::milliseconds(packet[6] | (packet[7] << 8)));
                    if (!ready) response = 1;
                }
            }
            send(fd, &response, 1, 0); close(fd);
        }
        release(); std::this_thread::sleep_for(100ms);
        client->async_virtual_hid_keyboard_terminate();
        std::this_thread::sleep_for(100ms);
        client.reset();
    }
    pqrs::dispatcher::extra::terminate_shared_dispatcher();
    close(server); unlink(socketPath);
    if (ownedDaemon > 0) { kill(ownedDaemon, SIGTERM); waitpid(ownedDaemon, nullptr, 0); }
    return 0;
}

// Owns only the command it spawns. stdin is a lifetime pipe held by LayerLens.
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;
static volatile sig_atomic_t stopping;
static void stop(int signal) { (void)signal; stopping = 1; }
static int disconnected(int timeout) {
    struct pollfd pipe = { .fd = STDIN_FILENO, .events = POLLIN | POLLHUP };
    int result = poll(&pipe, 1, timeout);
    if (result < 0) return errno != EINTR;
    if (!result) return 0;
    // No payload is part of this protocol; EOF, unexpected bytes or errors close it.
    return pipe.revents != 0;
}

int main(int argc, char **argv) {
    if (argc < 3) return 64;
    char *end = NULL;
    long parent = strtol(argv[1], &end, 10);
    if (!end || *end || parent <= 1 || getppid() != parent || disconnected(0)) return 0;
    struct sigaction action = { .sa_handler = stop };
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);

    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT);
    posix_spawnattr_setpgroup(&attributes, 0);
    posix_spawn_file_actions_t files;
    posix_spawn_file_actions_init(&files);
    // Never let the command inherit the lifetime pipe.
    posix_spawn_file_actions_addopen(&files, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&files, STDOUT_FILENO, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&files, STDERR_FILENO, STDERR_FILENO);
    pid_t child = -1;
    int error = posix_spawn(&child, argv[2], &files, &attributes, argv + 2, environ);
    posix_spawn_file_actions_destroy(&files);
    posix_spawnattr_destroy(&attributes);
    if (error) return 70;

    int status = 0;
    while (!stopping && getppid() == parent && !disconnected(50)) {
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child) return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
        if (result < 0 && errno != EINTR) return 1;
    }
    // Signal only our own command's group; never shared CoreDevice services.
    kill(-child, SIGTERM);
    for (int attempt = 0; attempt < 10; ++attempt) {
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child || (result < 0 && errno == ECHILD)) return 0;
        struct timespec delay = { .tv_nsec = 50000000 };
        nanosleep(&delay, NULL);
    }
    kill(-child, SIGKILL);
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    return 0;
}

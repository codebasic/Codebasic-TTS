#include <errno.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

/* A native app's main executable launching a direct MCP stdio child. */
int main(int argc, char **argv) {
    if (argc < 2) return 64;
    pid_t child = fork();
    if (child < 0) return 71;
    if (child == 0) {
        execv(argv[1], argv + 1);
        _exit(71);
    }

    close(STDIN_FILENO);
    close(STDOUT_FILENO);
    int status;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) return 71;
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 71;
}

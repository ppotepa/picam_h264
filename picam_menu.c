// picam_menu.c
// Interactive menu launcher for picam benchmarking commands
// Provides a simple text menu to quickly run frequently used
// camera benchmarking commands without retyping them each time.
//
// Build:   gcc -O2 -Wall -o picam_menu picam_menu.c
// Runtime: requires ./picam and ./picam.sh executables  
// Usage:   ./picam_menu or LOG_FILE=menu.log ./picam_menu
// License: MIT

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MAX_COMMANDS 50
#define MAX_NAME_LEN 128
#define MAX_CMD_LEN 512

typedef struct
{
    char name[MAX_NAME_LEN];
    char command[MAX_CMD_LEN];
} menu_entry_t;

static menu_entry_t menu_entries[MAX_COMMANDS];
static int entry_count = 0;

// Add a menu entry
static void add_entry(const char *name, const char *command)
{
    if (entry_count >= MAX_COMMANDS)
    {
        fprintf(stderr, "Error: Too many menu entries\n");
        return;
    }

    strncpy(menu_entries[entry_count].name, name, MAX_NAME_LEN - 1);
    menu_entries[entry_count].name[MAX_NAME_LEN - 1] = '\0';

    strncpy(menu_entries[entry_count].command, command, MAX_CMD_LEN - 1);
    menu_entries[entry_count].command[MAX_CMD_LEN - 1] = '\0';

    entry_count++;
}

// Initialize all menu entries
static void init_menu_entries(void)
{
    // Build and Setup
    add_entry("Build C implementation", "./build.sh");
    add_entry("Debug camera detection (bash)", "./picam.sh --debug-cameras");
    add_entry("List cameras (C version)", "./picam --list-cameras");
    add_entry("Test USB camera (bash)", "./picam.sh --test-usb");

    // Bash Script Tests - Various Resolutions and Settings
    add_entry("Bash: 640x480 30fps auto-detect", "./picam.sh --no-menu --resolution 640x480 --fps 30 --duration 10");
    add_entry("Bash: 1280x720 30fps auto-detect", "./picam.sh --no-menu --resolution 1280x720 --fps 30 --duration 15");
    add_entry("Bash: 1920x1080 25fps high quality", "./picam.sh --no-menu --resolution 1920x1080 --fps 25 --duration 10");
    add_entry("Bash: 1280x720 60fps performance test", "./picam.sh --no-menu --resolution 1280x720 --fps 60 --duration 8");
    add_entry("Bash: 800x600 25fps test", "./picam.sh --no-menu --resolution 800x600 --fps 25 --duration 15");
    add_entry("Bash: 1920x1080 15fps test", "./picam.sh --no-menu --resolution 1920x1080 --fps 15 --duration 20");
    add_entry("Bash: 1280x720 30fps KMS display", "./picam.sh --no-menu --resolution 1280x720 --fps 30 --display kms --duration 10");
    add_entry("Bash: 640x480 15fps infinite test", "./picam.sh --no-menu --resolution 640x480 --fps 15");
    add_entry("Bash: 1600x1200 20fps test", "./picam.sh --no-menu --resolution 1600x1200 --fps 20 --duration 12");
    add_entry("Bash: USB camera /dev/video0", "./picam.sh --no-menu --source /dev/video0 --resolution 640x480 --fps 30 --duration 10");

    // C Implementation Tests - Various Configurations
    add_entry("C: 640x480 30fps USB /dev/video0", "./picam --source /dev/video0 --resolution 640x480 --fps 30 --bitrate 1000000 --duration 10");
    add_entry("C: 1280x720 30fps auto-detect", "./picam --source auto --resolution 1280x720 --fps 30 --bitrate 4000000 --duration 15");
    add_entry("C: 1920x1080 25fps CSI camera", "./picam --source csi --resolution 1920x1080 --fps 25 --bitrate 8000000 --duration 10");
    add_entry("C: 1920x1080 30fps USB hardware encode", "./picam --source /dev/video0 --encode hardware --resolution 1920x1080 --fps 30 --bitrate 6000000 --duration 12");
    add_entry("C: 1280x720 60fps software encode", "./picam --source auto --encode software --resolution 1280x720 --fps 60 --bitrate 5000000 --duration 8");
    add_entry("C: 800x600 25fps low bitrate", "./picam --source auto --resolution 800x600 --fps 25 --bitrate 2000000 --duration 15");
    add_entry("C: 1920x1080 15fps high bitrate CSI", "./picam --source csi --resolution 1920x1080 --fps 15 --bitrate 10000000 --duration 20");
    add_entry("C: 1280x720 30fps framebuffer out", "./picam --source auto --resolution 1280x720 --fps 30 --bitrate 4000000 --framebuffer --duration 10");
    add_entry("C: 640x480 15fps USB infinite", "./picam --source /dev/video0 --resolution 640x480 --fps 15 --bitrate 1500000");
    add_entry("C: 1600x1200 20fps auto-detect", "./picam --source auto --resolution 1600x1200 --fps 20 --bitrate 7000000 --duration 12");

    // Special Tests and Interactive Modes
    add_entry("Bash: Interactive menu wizard", "./picam.sh");
    add_entry("Bash: Verbose mode test", "./picam.sh --no-menu --resolution 1280x720 --fps 30 --duration 5 --verbose");
    add_entry("Bash: Quiet mode test", "./picam.sh --no-menu --resolution 1280x720 --fps 30 --duration 5 --quiet");
    add_entry("Bash: Framebuffer display", "./picam.sh --no-menu --resolution 1280x720 --fps 30 --duration 10 --display fb");
    add_entry("Bash: Dry run (show pipeline)", "./picam.sh --no-menu --resolution 1280x720 --fps 30 --dry-run");
    add_entry("C: No overlay performance test", "./picam --no-overlay --source auto --resolution 1920x1080 --fps 30 --bitrate 6000000 --duration 10");
    add_entry("C: Verbose logging test", "./picam --source auto --resolution 1280x720 --fps 30 --bitrate 4000000 --duration 5 --verbose");
    add_entry("C: Quiet mode test", "./picam --source auto --resolution 1280x720 --fps 30 --bitrate 4000000 --duration 5 --quiet");
    add_entry("Stress Test: 4K 30fps (if supported)", "./picam --source auto --resolution 3840x2160 --fps 30 --bitrate 20000000 --duration 5");
    add_entry("Quick Test: 480p 15fps low impact", "./picam --source auto --resolution 640x480 --fps 15 --bitrate 800000 --duration 5");
}

// Get current timestamp as string
static void get_timestamp(char *buffer, size_t size)
{
    time_t rawtime;
    struct tm *timeinfo;

    time(&rawtime);
    timeinfo = localtime(&rawtime);

    strftime(buffer, size, "%H:%M:%S", timeinfo);
}

// Log message to file if LOG_FILE environment variable is set
static void log_to_file(const char *message)
{
    const char *log_file = getenv("LOG_FILE");
    if (!log_file || !*log_file)
    {
        return;
    }

    FILE *fp = fopen(log_file, "a");
    if (fp)
    {
        char timestamp[32];
        get_timestamp(timestamp, sizeof(timestamp));
        fprintf(fp, "[%s] %s\n", timestamp, message);
        fclose(fp);
    }
}

// Print the menu
static void print_menu(void)
{
    char cwd[512];
    if (getcwd(cwd, sizeof(cwd)) == NULL) {
        strcpy(cwd, "unknown");
    }
    
    printf("\n");
    printf("PiCam Benchmarking Menu (C Version) - %s\n", cwd);
    printf("Select an action:\n");

    for (int i = 0; i < entry_count; i++)
    {
        printf("  %d) %s\n", i + 1, menu_entries[i].name);
    }

    printf("  c) Custom command\n");
    printf("  q) Quit\n");
    printf("\n");
}

// Execute a command and track its execution
static int run_command(const char *command)
{
    char timestamp[32];
    char log_msg[1024];
    char cwd[512];

    if (getcwd(cwd, sizeof(cwd)) == NULL) {
        strcpy(cwd, "unknown");
    }

    get_timestamp(timestamp, sizeof(timestamp));

    printf("\n");
    printf("========================================\n");
    printf("[%s] Executing: %s\n", timestamp, command);
    printf("Working Directory: %s\n", cwd);
    printf("========================================\n");
    printf("\n");

    // Log to file if LOG_FILE is set
    snprintf(log_msg, sizeof(log_msg), "Menu executed: %s", command);
    log_to_file(log_msg);

    // Check if main executables exist before running
    if (strstr(command, "./picam ") && access("./picam", X_OK) != 0) {
        printf("ERROR: ./picam executable not found or not executable. Run './build.sh' first.\n");
        return 127;
    }
    
    if (strstr(command, "./picam.sh") && access("./picam.sh", X_OK) != 0) {
        printf("ERROR: ./picam.sh script not found or not executable.\n");
        return 127;
    }

    // Execute the command
    int exit_code = system(command);
    if (exit_code == -1)
    {
        printf("Error: Failed to execute command\n");
        exit_code = 127;
    }
    else
    {
        exit_code = WEXITSTATUS(exit_code);
    }

    get_timestamp(timestamp, sizeof(timestamp));

    printf("\n");
    printf("========================================\n");
    printf("[%s] Command completed with exit code: %d\n", timestamp, exit_code);
    printf("========================================\n");

    // Log completion
    snprintf(log_msg, sizeof(log_msg), "Command completed with exit code: %d", exit_code);
    log_to_file(log_msg);

    return exit_code;
}

// Get user input safely
static int get_user_input(char *buffer, size_t size)
{
    if (!fgets(buffer, size, stdin))
    {
        return -1;
    }

    // Remove trailing newline
    size_t len = strlen(buffer);
    if (len > 0 && buffer[len - 1] == '\n')
    {
        buffer[len - 1] = '\0';
    }

    return 0;
}

// Main menu loop
int main(void)
{
    char input[256];
    char custom_command[512];
    char cwd[512];
    int choice;

    // Initialize menu entries
    init_menu_entries();

    printf("=====================================\n");
    printf("PiCam Benchmarking Menu (C Version)\n");
    printf("====================================\n");
    printf("Working Directory: %s\n", getcwd(cwd, sizeof(cwd)) ? cwd : "unknown");
    if (getenv("LOG_FILE")) {
        printf("Logging to: %s\n", getenv("LOG_FILE"));
    }
    printf("\n");

    while (1)
    {
        print_menu();
        printf("Enter choice: ");
        fflush(stdout);

        if (get_user_input(input, sizeof(input)) < 0)
        {
            break;
        }

        // Handle empty input
        if (strlen(input) == 0)
        {
            continue;
        }

        // Handle quit commands
        if (strcasecmp(input, "q") == 0 ||
            strcasecmp(input, "quit") == 0 ||
            strcasecmp(input, "exit") == 0)
        {
            printf("Bye!\n");
            break;
        }

        // Handle custom command
        if (strcasecmp(input, "c") == 0)
        {
            printf("Enter custom command: ");
            fflush(stdout);

            if (get_user_input(custom_command, sizeof(custom_command)) < 0)
            {
                continue;
            }

            if (strlen(custom_command) == 0)
            {
                continue;
            }

            run_command(custom_command);
        }
        // Handle numeric choices
        else
        {
            choice = atoi(input);
            if (choice >= 1 && choice <= entry_count)
            {
                run_command(menu_entries[choice - 1].command);
            }
            else
            {
                printf("Invalid choice: %s\n", input);
                continue;
            }
        }

        printf("\nPress Enter to return to menu...");
        fflush(stdout);
        get_user_input(input, sizeof(input));
        printf("\n");
    }

    return 0;
}
#import "ProbeInventory.h"

#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *env_or_unset(const char *key) {
  const char *value = getenv(key);
  return value ? value : "(unset)";
}

static bool has_flag(int argc, char **argv, const char *flag) {
  for (int index = 1; index < argc; index++) {
    if (strcmp(argv[index], flag) == 0)
      return true;
  }
  return false;
}

static int parse_int_arg(int argc, char **argv, const char *name, int fallback,
                         int minimum, int maximum) {
  for (int index = 1; index + 1 < argc; index++) {
    if (strcmp(argv[index], name) == 0) {
      int value = atoi(argv[index + 1]);
      return value < minimum ? minimum : (value > maximum ? maximum : value);
    }
  }
  return fallback;
}

static const char *parse_mappings_file(int argc, char **argv) {
  for (int index = 1; index + 1 < argc; index++) {
    if (strcmp(argv[index], "--mappings-file") == 0)
      return argv[index + 1];
  }
  return NULL;
}

static void print_environment(void) {
  int version = SDL_GetVersion();
  printf("SDL linked version: %d.%d.%d (raw=%d)\n", SDL_VERSIONNUM_MAJOR(version),
         SDL_VERSIONNUM_MINOR(version), SDL_VERSIONNUM_MICRO(version), version);
  printf("SDL platform: %s\n", SDL_GetPlatform());
  printf("SDL_JOYSTICK_MFI=%s\n", env_or_unset("SDL_JOYSTICK_MFI"));
  printf("SDL_JOYSTICK_IOKIT=%s\n", env_or_unset("SDL_JOYSTICK_IOKIT"));
  printf("SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=%s\n",
         env_or_unset("SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS"));
  printf("SDL_JOYSTICK_HIDAPI_XBOX=%s\n", env_or_unset("SDL_JOYSTICK_HIDAPI_XBOX"));
  printf("SDL_JOYSTICK_HIDAPI_XBOX_ONE=%s\n",
         env_or_unset("SDL_JOYSTICK_HIDAPI_XBOX_ONE"));
}

static void print_events(int seconds, SDL_JoystickID *joy_ids, int joy_count,
                         SDL_Gamepad **gamepads) {
  printf("\nListening for %ds (press buttons now) ...\n", seconds);
  Uint64 start = SDL_GetTicks();
  while ((SDL_GetTicks() - start) < (Uint64)(seconds * 1000)) {
    SDL_UpdateGamepads();
    SDL_Event event;
    while (SDL_PollEvent(&event)) {
      switch (event.type) {
      case SDL_EVENT_GAMEPAD_BUTTON_DOWN:
      case SDL_EVENT_GAMEPAD_BUTTON_UP:
        printf("GAMEPAD_BUTTON %s which=%u button=%d\n",
               event.type == SDL_EVENT_GAMEPAD_BUTTON_DOWN ? "down" : "up",
               (unsigned)event.gbutton.which, (int)event.gbutton.button);
        break;
      case SDL_EVENT_GAMEPAD_AXIS_MOTION:
        if (abs((int)event.gaxis.value) > 8000)
          printf("GAMEPAD_AXIS which=%u axis=%d value=%d\n", (unsigned)event.gaxis.which,
                 (int)event.gaxis.axis, (int)event.gaxis.value);
        break;
      default:
        break;
      }
    }
    for (int index = 0; index < joy_count; index++) {
      if (gamepads[index])
        SDL_UpdateGamepads();
    }
    SDL_Delay(1);
  }
  (void)joy_ids;
}

static int rumble_gamepads(SDL_JoystickID *joy_ids, int joy_count, SDL_Gamepad **gamepads) {
  int attempts = 0;
  int failures = 0;
  printf("\nMain-motor rumble probe:\n");
  for (int index = 0; index < joy_count; index++) {
    if (!gamepads[index])
      continue;
    attempts++;
    bool ok = SDL_RumbleGamepad(gamepads[index], 0x9000, 0x6000, 300);
    failures += !ok;
    printf("- id=%u SDL_RumbleGamepad=%s%s%s\n", (unsigned)joy_ids[index],
           ok ? "ok" : "failed", ok ? "" : " error=", ok ? "" : SDL_GetError());
  }
  return attempts == 0 || failures > 0 ? 4 : 0;
}

int main(int argc, char **argv) {
  int seconds = parse_int_arg(argc, argv, "--seconds", 10, 1, 60);
  int wait_seconds = parse_int_arg(argc, argv, "--wait-devices", 0, 0, 30);
  bool rumble = has_flag(argc, argv, "--rumble");
  bool expect_rumble = has_flag(argc, argv, "--expect-rumble");
  bool expect_neutral = has_flag(argc, argv, "--expect-single-neutral-ojd");
  print_environment();
  if (has_flag(argc, argv, "--gc-prewarm"))
    OJDProbePrewarmGameController();

  SDL_InitFlags flags = SDL_INIT_GAMEPAD | SDL_INIT_JOYSTICK | SDL_INIT_HAPTIC | SDL_INIT_EVENTS;
  if (has_flag(argc, argv, "--video"))
    flags |= SDL_INIT_VIDEO;
  if (!SDL_Init(flags)) {
    fprintf(stderr, "ERROR: SDL_Init failed: %s\n", SDL_GetError());
    return 2;
  }
  SDL_SetGamepadEventsEnabled(true);
  const char *mappings_file = parse_mappings_file(argc, argv);
  if (mappings_file)
    printf("Loaded mappings: %d (%s)\n", SDL_AddGamepadMappingsFromFile(mappings_file), mappings_file);

  int joy_count = 0;
  SDL_JoystickID *joy_ids = OJDProbeWaitForJoysticks(wait_seconds, &joy_count);
  printf("\nFound %d joystick(s)\n", joy_count);
  SDL_Gamepad **gamepads = calloc((size_t)joy_count, sizeof(*gamepads));
  if (joy_count > 0 && !gamepads) {
    fprintf(stderr, "ERROR: calloc failed: %s\n", strerror(errno));
    SDL_free(joy_ids);
    SDL_Quit();
    return 2;
  }
  for (int index = 0; index < joy_count; index++) {
    OJDProbePrintJoystick(joy_ids[index]);
    if (SDL_IsGamepad(joy_ids[index]))
      gamepads[index] = SDL_OpenGamepad(joy_ids[index]);
  }
  int result = expect_neutral ? OJDProbeCheckSingleNeutralOJD(joy_ids, joy_count) : 0;
  int rumble_result = 0;
  if (rumble) {
    rumble_result = rumble_gamepads(joy_ids, joy_count, gamepads);
  }
  if (expect_rumble && rumble_result == 0 && !rumble)
    rumble_result = 4;
  if (expect_rumble && rumble_result)
    result = rumble_result;
  print_events(seconds, joy_ids, joy_count, gamepads);
  for (int index = 0; index < joy_count; index++) {
    if (gamepads[index]) {
      if (rumble)
        SDL_RumbleGamepad(gamepads[index], 0, 0, 0);
      SDL_CloseGamepad(gamepads[index]);
    }
  }
  free(gamepads);
  SDL_free(joy_ids);
  SDL_Quit();
  return result;
}

set_project("SDLGamepadProbe")
set_languages("c11")
set_toolchains("clang")

add_requires("pkgconfig::sdl3", {system = true})

target("SDLGamepadProbe")
  set_kind("binary")
  add_files("*.m")
  add_packages("pkgconfig::sdl3")
  add_frameworks("Foundation", "GameController")

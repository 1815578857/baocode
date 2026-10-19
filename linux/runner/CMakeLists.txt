cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "clipboard.cc"
  "login_window.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)

# WebKitGTK, for the channel build's login window (login_window.cc), where
# it is installed (libwebkit2gtk-4.1-dev); without it, the window says so.
pkg_check_modules(WEBKIT IMPORTED_TARGET webkit2gtk-4.1>=2.40)
if(WEBKIT_FOUND)
  target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::WEBKIT)
  target_compile_definitions(${BINARY_NAME} PRIVATE HAVE_WEBKIT)
endif()

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

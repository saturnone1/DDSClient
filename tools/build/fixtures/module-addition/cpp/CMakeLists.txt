cmake_minimum_required(VERSION 3.20)
project(FrozenCoreModuleAddition LANGUAGES CXX)

# The caller points DDSClient_DIR at the copied installed package. No source
# checkout, add_subdirectory(Core), or built-in message library is involved.
find_package(DDSClient CONFIG REQUIRED NO_DEFAULT_PATH PATHS "${DDSClient_DIR}")
if(DDSClient_USE_STATIC_LIBS)
    set(core_target DDSClient::dds_cpp_static)
else()
    set(core_target DDSClient::dds_cpp_shared)
endif()
if(NOT TARGET ${core_target})
    message(FATAL_ERROR "Frozen package does not provide ${core_target}")
endif()
get_target_property(core_imported ${core_target} IMPORTED)
if(NOT core_imported)
    message(FATAL_ERROR "Core must be an installed imported binary")
endif()
file(GENERATE OUTPUT "${CMAKE_BINARY_DIR}/linked-core-$<CONFIG>.txt"
    CONTENT "$<TARGET_FILE:${core_target}>")

add_library(added_after_freeze STATIC
    "${GENERATED_MODULE_DIR}/AddedAfterFreezeMessages.cpp"
    "${GENERATED_MODULE_DIR}/AddedAfterFreeze.cxx"
    "${GENERATED_MODULE_DIR}/AddedAfterFreezePlugin.cxx")
target_compile_features(added_after_freeze PUBLIC cxx_std_20)
target_include_directories(added_after_freeze PUBLIC
    "${GENERATED_MODULE_DIR}")
target_link_libraries(added_after_freeze PUBLIC ${core_target})

add_executable(module_addition_consumer main.cpp)
target_link_libraries(module_addition_consumer PRIVATE added_after_freeze)
set_target_properties(module_addition_consumer PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
foreach(config Debug Release RelWithDebInfo MinSizeRel)
    string(TOUPPER "${config}" config_upper)
    set_target_properties(module_addition_consumer PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY_${config_upper} "${CMAKE_BINARY_DIR}/bin")
endforeach()
if(WIN32 AND NOT DDSClient_USE_STATIC_LIBS)
    add_custom_command(TARGET module_addition_consumer POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "$<TARGET_FILE:${core_target}>"
            "$<TARGET_FILE_DIR:module_addition_consumer>" VERBATIM)
endif()

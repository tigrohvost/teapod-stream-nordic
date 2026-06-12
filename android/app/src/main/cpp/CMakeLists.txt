cmake_minimum_required(VERSION 3.22.1)
project("vpnhelper")

add_library(vpnhelper SHARED vpn_helper.c)

find_library(log-lib log)
target_link_libraries(vpnhelper ${log-lib})

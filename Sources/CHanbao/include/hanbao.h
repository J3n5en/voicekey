#pragma once
// 离线识别 worker（arm64）：hanbao_main(argc, argv)，argv = {_, "--pipe", model}，HB_LIBDIR 指向 so 目录
int hanbao_main(int argc, char **argv);

#include "boot.h"
#include <iostream>

// this function is for sanity check only
void print_julia_version(void) {
  const char *ptr = jl_ver_string();
  std::string s(ptr);
  std::cout << s << std::endl;
}

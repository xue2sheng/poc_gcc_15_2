# gcc 15.2 for several targets

Although there are different targets, the last stage is **Ubuntu 24.04**

# MUSL

Do not forget to statically compile once your g++ points to */opt/toolchain/gcc15-musl/bin/g++*

**main.cpp**

    #include <print>
    int main() {
            std::println("Hello World!");
            return 0;
    }

**Makefile**

    all: main.cpp
        g++ -std=c++23 -static -o test001 main.cpp
    clean: test001
        rm -rf test001

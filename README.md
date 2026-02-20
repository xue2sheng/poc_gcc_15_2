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

### Regarding **TBB**

**main.cpp**

    #include <tbb/parallel_for.h>
    #include <tbb/parallel_sort.h> // Moved to global scope
    #include <tbb/global_control.h>
    #include <vector>
    #include <algorithm>
    #include <print>
    #include <numeric>
    int main() {
        const int size = 10'000'000;
        std::vector<int> data(size);
        // Initialize data in parallel
        tbb::parallel_for(tbb::blocked_range<size_t>(0, size), [&](const tbb::blocked_range<size_t>& r) {
            for (size_t i = r.begin(); i != r.end(); ++i) {
                data[i] = static_cast<int>(size - i);
            }
        });
        std::println("Data initialized. Sorting {} elements...", size);
        // Now this will work perfectly
        tbb::parallel_sort(data.begin(), data.end());
        std::println("First 5 elements: {}, {}, {}, {}, {}", data[0], data[1], data[2], data[3], data[4]);
        return 0;
    }

**Makefile**

    CXX      = g++
    CXXFLAGS = -std=c++23 -O3 -Wall -Wextra
    LDFLAGS  = -static-libstdc++ -static-libgcc
    # TBB Paths (Adjust if you installed to a custom directory)
    TBB_DIR  = /opt/toolchain/gcc15-musl/tbb
    INCLUDES = -I$(TBB_DIR)/include
    LIBS     = $(TBB_DIR)/lib/libtbb.a
    # Musl requires pthread and math libraries for TBB
    LDLIBS   = -lpthread -lm
    # Target
    TARGET   = tbb_example
    SRC      = main.cpp
    all: $(TARGET)
    $(TARGET): $(SRC)
            $(CXX) $(CXXFLAGS) $(INCLUDES) $(SRC) -o $(TARGET) $(LIBS) $(LDFLAGS) $(LDLIBS)
    clean:
            rm -f $(TARGET)
    .PHONY: all clean

### Regarding **boost**

**main.cpp**

    #include <iostream>
    #include <print>         // C++23
    #include <boost/asio.hpp>
    #include <chrono>
    int main() {
        // C++23 std::print
        std::print("Hello from C++23 and Boost Asio!\n");
        boost::asio::io_context io;
        // Set a timer for 1 second
        boost::asio::steady_timer t(io, boost::asio::chrono::seconds(1));
        std::print("Waiting for timer...\n");
        t.wait();
        std::print("Timer expired. Goodbye!\n");
        return 0;
    }

**Makefile**

    TOOLCHAIN = /opt/toolchain/gcc15-musl
    CXX = $(TOOLCHAIN)/bin/g++
    BOOST_ROOT = $(TOOLCHAIN)/boost
    # C++23 flag
    CXXFLAGS = -std=c++23 -O3
    # Include paths
    INCLUDES = -I$(BOOST_ROOT)/include
    # Linker flags
    # We use -static to ensure it links against the musl sysroot
    # rather than looking for Ubuntu's glibc.
    LDFLAGS = -static -L$(BOOST_ROOT)/lib
    LIBS = -lpthread
    TARGET = hello_musl
    all: $(TARGET)
    $(TARGET): main.cpp
        $(CXX) $(CXXFLAGS) $(INCLUDES) main.cpp -o $(TARGET) $(LDFLAGS) $(LIBS)
    clean:
        rm -f $(TARGET)

### Regarding **gnuplot**

If you're on Windows, you might be interested in installing MobaXTerm and run its included XServer before launching the docker container with **DISPLAY** configured:

    docker run -it -e DISPLAY=host.docker.internal:0.0 poc_gcc_15_2

**main.cpp**

    #include <vector>
    #include <cmath>
    #include <print>
    #include <utility>
    // Boost dependencies for gnuplot-iostream
    #include <boost/range/adaptor/transformed.hpp>
    #include <boost/range/irange.hpp>
    // This is often the missing link for std::pair support
    #include <boost/tuple/tuple.hpp>
    #include "gnuplot-iostream.h"
    int main() {
        // Open gnuplot process
        gnuplotio::Gnuplot gp;
        // Create some data using standard pair
        std::vector<std::pair<double, double>> points;
        for(double x = -5; x < 5; x += 0.1) {
            points.push_back({x, std::sin(x)});
        }
        std::print("Sending data to gnuplot...\n");
        // Use the dumb terminal to verify in the console
        gp << "set terminal dumb\n";
        gp << "plot '-' with lines title 'C++23 Static Sin Wave'\n";
        // Use send1d (more explicit than <<) if operator overloading fails
        gp.send1d(points);
        return 0;
    }

**Makefile**

    TOOLCHAIN = /opt/toolchain/gcc15-musl
    CXX = $(TOOLCHAIN)/bin/g++
    BOOST_ROOT = $(TOOLCHAIN)/boost
    GNUPLOT_ROOT = $(TOOLCHAIN)/gnuplot
    CXXFLAGS = -std=c++23 -O3
    INCLUDES = -I$(BOOST_ROOT)/include -I$(GNUPLOT_ROOT)/include
    # Note: The order of libraries is important for static linking
    LDFLAGS = -static -L$(BOOST_ROOT)/lib
    LIBS = -lboost_iostreams -lboost_filesystem -lpthread
    TARGET = gnuplot_test
    all: $(TARGET)
    $(TARGET): main.cpp
            $(CXX) $(CXXFLAGS) $(INCLUDES) main.cpp -o $(TARGET) $(LDFLAGS) $(LIBS)
    clean:
            rm -f $(TARGET)

### Regarding libpqxx

That helper to connect to **Postgres** requires *openssl* and *libpq*. Besides, *cmake* version 4.x is a must

**main.cpp**

    #include <iostream>
    #include <print>
    #include <pqxx/pqxx>
    int main() {
        // libpqxx version is available via this string
        std::string version = PQXX_VERSION;
        std::println("Hello from GCC 15 + Musl!");
        std::println("libpqxx version: {}", version);
        return 0;
    }

**Makefile**

    # --- Path Configuration ---
    TOOLCHAIN = /opt/toolchain/gcc15-musl
    PREFIX    = $(TOOLCHAIN)
    # Compiler definitions
    CXX      = $(TOOLCHAIN)/bin/g++
    CXXFLAGS = -std=c++23 -O3 --sysroot=$(TOOLCHAIN)/sysroot \
               -I$(PREFIX)/libpqxx/include \
               -I$(PREFIX)/postgres/include \
               -I$(PREFIX)/openssl/include
    # --- Library Paths ---
    LDFLAGS  = -L$(PREFIX)/libpqxx/lib \
               -L$(PREFIX)/postgres/lib \
               -L$(PREFIX)/openssl/lib64 \
               -lpqxx \
               -lpq \
               -lpgcommon \
               -lpgport \
               -lssl \
               -lcrypto \
               -static
    # --- Targets ---
    all: hello_pqxx
    hello_pqxx: main.cpp
        $(CXX) $(CXXFLAGS) main.cpp -o hello_pqxx $(LDFLAGS)
    clean:
        rm -f hello_pqxx

### Regarding google-test

**main.cpp**

    #include <gtest/gtest.h>
    // A simple function to test
    int add(int a, int b) {
        return a + b;
    }
    TEST(AdditionTest, HandlesPositiveNumbers) {
        EXPECT_EQ(add(1, 2), 3);
    }
    TEST(AdditionTest, HandlesZero) {
        EXPECT_EQ(add(0, 0), 0);
    }

**Makefile**

    TOOLCHAIN_ROOT = /opt/toolchain/gcc15-musl
    SYSROOT        = $(TOOLCHAIN_ROOT)/sysroot
    GTEST_ROOT     = $(TOOLCHAIN_ROOT)/googletest
    # Compilers
    CXX = $(TOOLCHAIN_ROOT)/bin/g++
    CC  = $(TOOLCHAIN_ROOT)/bin/gcc
    # Flags
    # --sysroot: tells g++ where to find musl headers/libs
    # -static:   ensures a completely standalone binary
    CXXFLAGS = --sysroot=$(SYSROOT) -I$(GTEST_ROOT)/include -std=c++20 -static -O2
    LDFLAGS  = --sysroot=$(SYSROOT) -L$(GTEST_ROOT)/lib -static
    # Libraries
    # Order matters: gtest_main depends on gtest
    LIBS = -lgtest_main -lgtest -lpthread
    TARGET = hello_gtest
    all: $(TARGET)
    $(TARGET): main.cpp
            $(CXX) $(CXXFLAGS) main.cpp $(LDFLAGS) $(LIBS) -o $(TARGET)
    clean:
            rm -f $(TARGET)
    test: all
            ./$(TARGET)

# ALMALINUX 9 / REDHAT 9

In this case, we're not looking for statically built executables but for cross-built ones using original Almalinux 9 libc and related libraries.

The aim here is to be able to cross-build c/c++ shared libraries on Ubuntu 24.04 that can be used by **python** on AlmaLimux 9 / RedHat 9.

**main.cpp**

    #include <print>
    int main() {
            std::println("Hello World!");
            return 0;
    }

**Makefile**

    CXX = /opt/chaintool/gcc15-almalinux/bin/g++
    SYSROOT = /opt/chaintool/gcc15-almalinux/sysroot
    GCC_LIB = /opt/chaintool/gcc15-almalinux/lib64
    all: main.cpp
            $(CXX) -std=c++23 main.cpp -o test002 \
                --sysroot=$(SYSROOT) \
                -B$(SYSROOT)/usr/lib64 \
                -L$(SYSROOT)/usr/lib64 \
                -L$(GCC_LIB) \
                -static-libstdc++ \
                -static-libgcc \
                -Wl,--start-group -lc -lm -lgcc_s -Wl,--end-group \
                $(SYSROOT)/usr/lib64/ld-linux-x86-64.so.2 \
                -Wl,-rpath-link,$(SYSROOT)/lib64
    clean: test002
            rm -rf test002

If you prefer **CMake** with your binaries in a different location at **$HOME**, you might go for

**CMakeLists.txt**

    cmake_minimum_required(VERSION 3.25)
    project(TestProject LANGUAGES CXX)
    # 1. Path Definitions (Matching your Makefile)
    set(TOOLCHAIN_BIN "$ENV{HOME}/toolchain/gcc15-almalinux/bin/g++")
    set(MY_SYSROOT "$ENV{HOME}/toolchain/gcc15-almalinux/sysroot")
    set(GCC_LIB "$ENV{HOME}/toolchain/gcc15-almalinux/lib64")
    # 2. Configure Compiler and Sysroot
    set(CMAKE_CXX_COMPILER ${TOOLCHAIN_BIN})
    set(CMAKE_SYSROOT ${MY_SYSROOT})
    # 3. Define the Executable
    add_executable(test002 main.cpp)
    # 4. Set C++ Standard
    target_compile_features(test002 PRIVATE cxx_std_23)
    set(CMAKE_CXX_EXTENSIONS OFF)
    # 5. Compiler & Linker Flags
    target_compile_options(test002 PRIVATE "-B${MY_SYSROOT}/usr/lib64")
    target_link_options(test002 PRIVATE
        "-L${MY_SYSROOT}/usr/lib64"
        "-L${GCC_LIB}"
        "-static-libstdc++"
        "-static-libgcc"
        "LINKER:--start-group" "-lc" "-lm" "-lgcc_s" "LINKER:--end-group"
        "${MY_SYSROOT}/usr/lib64/ld-linux-x86-64.so.2"
        "LINKER:-rpath-link,${MY_SYSROOT}/lib64"
    )

### Regarding to Python

Here you are a little shared library to be cross-built on Ubuntu but invoked by python on AlmaLinux/RedHat.

Remember to locate your python caller script to reach the shared library.

**testingLib_caller.py**

    import ctypes
    TESTING_LIB = ctypes.CDLL('./build/testingLib.so')
    TESTING_LIB.type_something.argtypes = [ ctypes.c_char_p ]
    TESTING_LIB.type_something.restype = None 
    my_str = ctypes.c_char_p("Testing cross-built shared library".encode('utf-8'))
    TESTING_LIB.type_something(my_str)

**testingLib.hpp**

    #ifndef TESTINGLIB_H
    #define TESTINGLIB_H
    #ifdef __cplusplus
    extern "C" {
    #endif
    void type_something(char* str);
    #ifdef __cplusplus
    }
    #endif
    #endif // TESTINGLIB_H

**CMakeLists.txt**

    cmake_minimum_required(VERSION 3.20)
    set(CMAKE_CXX_COMPILER_WORKS TRUE)
    set(CMAKE_C_COMPILER_WORKS TRUE)
    set(CMAKE_C_COMPILER   "/opt/chaintool/gcc15-almalinux/bin/gcc")
    set(CMAKE_CXX_COMPILER "/opt/chaintool/gcc15-almalinux/bin/g++")
    project(testingLib CXX)
    set(SYSROOT "/opt/chaintool/gcc15-almalinux/sysroot")
    set(GCC_LIB "/opt/chaintool/gcc15-almalinux/lib64")
    set(CMAKE_CXX_STANDARD 23)
    # Compiler flags
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} \
        --sysroot=${SYSROOT} \
        -B${SYSROOT}/usr/lib64 \
        -static-libstdc++ -static-libgcc")
    # Linker flags
    set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} \
        -L${SYSROOT}/usr/lib64 \
        -L${GCC_LIB} \
        -Wl,--start-group -lc -lm -lgcc_s -Wl,--end-group \
        ${SYSROOT}/usr/lib64/ld-linux-x86-64.so.2 \
        -Wl,-rpath-link,${SYSROOT}/lib64")
    # Build shared library
    add_library(testingLib SHARED main.cpp)

**main.cpp**

    #include "testingLib.hpp"
    #include <print>
    void type_something(char* str) {
        std::println("Message: {}", str);
    }

### Regarding **TBB**

**main.cpp**

    #include <iostream>
    #include <vector>
    #include <oneapi/tbb.h>
    int main() {
        std::cout << "Hello from TBB! Starting parallel execution..." << std::endl;
        // A simple parallel loop to verify TBB is working
        tbb::parallel_for(tbb::blocked_range<int>(0, 10),
            [](const tbb::blocked_range<int>& r) {
                for (int i = r.begin(); i != r.end(); ++i) {
                    // Using printf because std::cout is not thread-safe and can scramble output
                    printf("TBB Task %d processed by thread\n", i);
                }
            });
        std::cout << "Parallel execution finished successfully." << std::endl;
        return 0;
    }

**Makefile**

    TOOLCHAIN_ROOT = /opt/toolchain/gcc15-almalinux
    SYSROOT        = $(TOOLCHAIN_ROOT)/sysroot
    TBB_ROOT       = $(TOOLCHAIN_ROOT)/tbb
    GCC_LIB        = $(TOOLCHAIN_ROOT)/lib64
    CXX = $(TOOLCHAIN_ROOT)/bin/g++
    # Compiler Flags
    CXXFLAGS = -std=c++23 \
               --sysroot=$(SYSROOT) \
               -B$(SYSROOT)/usr/lib64 \
               -I$(TBB_ROOT)/include \
               -O2
    # Linker Flags
    LDFLAGS = -static-libstdc++ \
              -static-libgcc \
              -L$(SYSROOT)/usr/lib64 \
              -L$(GCC_LIB) \
              -Wl,--start-group -lc -lm -lgcc_s -Wl,--end-group \
              $(SYSROOT)/usr/lib64/ld-linux-x86-64.so.2 \
              -Wl,-rpath-link,$(SYSROOT)/lib64
    all: tbb_hello
    tbb_hello: main.cpp
            $(CXX) $(CXXFLAGS) main.cpp $(TBB_ROOT)/lib64/libtbb.a -o tbb_hello $(LDFLAGS)
    clean:
            rm -f tbb_hello

### Regarding **Boost**

**main.cpp**

#include <print>
#include <vector>
#include <algorithm>
#include <boost/version.hpp>

    int main() {
        // Check Boost Version using C++23 std::print
        // BOOST_VERSION is formatted as MMmmpp (e.g., 109000 for 1.90.0)
        std::print("Using Boost version: {}.{}.{}\n", 
                   BOOST_VERSION / 100000,          // Major
                   BOOST_VERSION / 100 % 1000,      // Minor
                   BOOST_VERSION % 100);            // Patch
        // Modern C++ logic: Sorting with a lambda
        std::vector<int> nums = {3, 1, 4, 1, 5, 9};
        std::ranges::sort(nums); // Using C++20/23 ranges for brevity
        std::print("Sorted numbers: ");
        for (int n : nums) {
            std::print("{} ", n);
        }
        std::print("\nSuccess: GCC 15.2 and Boost 1.90.0 are working via std::print!\n");
        return 0;
    }

**Makefile**

    # --- Makefile ---
    TOOLCHAIN_ROOT = /opt/toolchain/gcc15-almalinux
    CXX = $(TOOLCHAIN_ROOT)/bin/g++
    BOOST_ROOT = $(TOOLCHAIN_ROOT)/boost
    SYSROOT = $(TOOLCHAIN_ROOT)/sysroot
    CXXFLAGS = -std=c++23 -O2 \
               --sysroot=$(SYSROOT) \
               -I$(BOOST_ROOT)/include
    # We add -Wl,--no-as-needed so the linker doesn't ignore the loader symbols
    # We also explicitly link against the loader SO you copied in Stage 1
    LDFLAGS = -B$(SYSROOT)/usr/lib64 \
              -L$(SYSROOT)/usr/lib64 \
              -L$(BOOST_ROOT)/lib \
              -static-libstdc++ \
              -static-libgcc \
              -Wl,--no-as-needed \
              $(SYSROOT)/usr/lib64/ld-linux-x86-64.so.2
    TARGET = boost_print_test
    all: $(TARGET)
    $(TARGET): main.cpp
            $(CXX) $(CXXFLAGS) main.cpp -o $(TARGET) $(LDFLAGS)
    clean:
            rm -f $(TARGET)

### Regarding **gnuplot**

**main.cpp**

    #include <vector>
    #include <cmath>
    #include <print>
    #include <utility>
    // Boost dependencies for gnuplot-iostream
    #include <boost/range/adaptor/transformed.hpp>
    #include <boost/range/irange.hpp>
    // This is often the missing link for std::pair support
    #include <boost/tuple/tuple.hpp>
    #include "gnuplot-iostream.h"
    int main() {
        // Open gnuplot process
        gnuplotio::Gnuplot gp;
        // Create some data using standard pair
        std::vector<std::pair<double, double>> points;
        for(double x = -5; x < 5; x += 0.1) {
            points.push_back({x, std::sin(x)});
        }
        std::print("Sending data to gnuplot...\n");
        // Use the dumb terminal to verify in the console
        gp << "set terminal dumb\n";
        gp << "plot '-' with lines title 'C++23 Static Sin Wave'\n";
        // Use send1d (more explicit than <<) if operator overloading fails
        gp.send1d(points);
        return 0;
    }

**Makefile**

    # --- Configuration ---
    TOOLCHAIN_ROOT = /opt/toolchain/gcc15-almalinux
    CXX          = $(TOOLCHAIN_ROOT)/bin/g++
    BOOST_ROOT   = $(TOOLCHAIN_ROOT)/boost
    SYSROOT      = $(TOOLCHAIN_ROOT)/sysroot
    GNUPLOT_INC  = $(TOOLCHAIN_ROOT)/gnuplot/include
    # --- Compiler Flags ---
    # -std=c++23 for std::print
    # --sysroot forces GCC to use AlmaLinux headers/libs
    CXXFLAGS = -std=c++23 -O2 \
               --sysroot=$(SYSROOT) \
               -I$(BOOST_ROOT)/include \
               -I$(GNUPLOT_INC)
    # --- Linker Flags ---
    # 1. -B: Where to find crt1.o, crti.o
    # 2. -L: Search paths for static libs
    # 3. Boost libs: Order matters (iostreams depends on system)
    # 4. Loader: Explicitly link AlmaLinux's ld-linux to resolve TLS/GLIBC symbols
    LDFLAGS = -B$(SYSROOT)/usr/lib64 \
              -L$(SYSROOT)/usr/lib64 \
              -L$(BOOST_ROOT)/lib \
              -static-libstdc++ \
              -static-libgcc \
              -lboost_iostreams \
              -lboost_filesystem \
              -Wl,--no-as-needed \
              $(SYSROOT)/usr/lib64/ld-linux-x86-64.so.2
    # --- Targets ---
    TARGET = gnuplot_test
    SRC    = main.cpp
    all: $(TARGET)
    $(TARGET): $(SRC)
            $(CXX) $(CXXFLAGS) $(SRC) -o $(TARGET) $(LDFLAGS)
    clean:
            rm -f $(TARGET)
    .PHONY: all clean

### Regarding **libpqxx**

**main.cpp**

    #include <iostream>
    #include <print>
    #include <pqxx/pqxx>
    int main() {
        // libpqxx version is available via this string
        std::string version = PQXX_VERSION;
        std::println("Hello from GCC 15 + Musl!");
        std::println("libpqxx version: {}", version);
        return 0;
    }

**Makefile**

    # Paths based on your PREFIX
    TOOLCHAIN_DIR = /opt/toolchain/gcc15-almalinux
    SYSROOT       = $(TOOLCHAIN_DIR)/sysroot
    CXX           = $(TOOLCHAIN_DIR)/bin/g++
    # Compiler flags
    # -std=c++23 is required for <print>
    CXXFLAGS = -std=c++23 -fPIC --sysroot=$(SYSROOT) \
               -I$(TOOLCHAIN_DIR)/libpqxx/include \
               -I$(TOOLCHAIN_DIR)/postgres/include \
               -I$(TOOLCHAIN_DIR)/openssl/include
    # Linker flags
    # We must use -L to point to our static .a files
    LDFLAGS = --sysroot=$(SYSROOT) \
              -L$(TOOLCHAIN_DIR)/libpqxx/lib64 \
              -L$(TOOLCHAIN_DIR)/postgres/lib \
              -L$(TOOLCHAIN_DIR)/openssl/lib64 \
              -L$(TOOLCHAIN_DIR)/openssl/lib
    # Static Linking Order (Crucial!)
    # libpqxx -> libpq -> postgres_internals -> openssl -> system_libs
    LIBS = -lpqxx -lpq -lpgcommon -lpgport -lssl -lcrypto
    TARGET = test_pqxx
    SRCS = main.cpp
    all: $(TARGET)
    $(TARGET): $(SRCS)
            $(CXX) $(CXXFLAGS) $(SRCS) -o $(TARGET) $(LDFLAGS) $(LIBS)
    clean:
            rm -f $(TARGET)

### Regarding **google test**

**main.cpp**

    #include <gtest/gtest.h>
    // A simple function to test
    int add(int a, int b) {
        return a + b;
    }
    TEST(AdditionTest, HandlesPositiveNumbers) {
        EXPECT_EQ(add(1, 2), 3);
    }
    TEST(AdditionTest, HandlesZero) {
        EXPECT_EQ(add(0, 0), 0);
    }

**Makefile**

    # Paths based on your setup
    TOOLCHAIN_DIR = /opt/toolchain/gcc15-almalinux
    SYSROOT       = $(TOOLCHAIN_DIR)/sysroot
    CXX           = $(TOOLCHAIN_DIR)/bin/g++
    # Compiler flags
    # GTest requires C++14 or newer; using C++23 for consistency with your GCC 15
    CXXFLAGS = -std=c++23 -fPIC --sysroot=$(SYSROOT) \
               -I$(TOOLCHAIN_DIR)/googletest/include
    # Linker flags
    LDFLAGS = --sysroot=$(SYSROOT) \
              -L$(TOOLCHAIN_DIR)/googletest/lib64 \
              -L$(TOOLCHAIN_DIR)/googletest/lib
    # Library Order: GTest Main provides the 'main()' function,
    # GTest is the core, and pthread is the system dependency.
    LIBS = -lgtest_main -lgtest
    TARGET = test_runner
    SRCS = main.cpp
    all: $(TARGET)
    $(TARGET): $(SRCS)
            $(CXX) $(CXXFLAGS) $(SRCS) -o $(TARGET) $(LDFLAGS) $(LIBS)
    clean:
            rm -f $(TARGET)
    run: $(TARGET)

# UBUNTU

Here you are aiming at building on the very same Ubuntu but using latest g++ compilers, debuggers, postgres ddbb, ....

**main.cpp**

    #include <print>
    int main() {
            std::println("Hello World!");
            return 0;
    }

**Makefile**

    # Toolchain Paths
    PREFIX      ?= /opt/toolchain/gcc15-ubuntu
    CXX         := $(PREFIX)/bin/g++
    CXXFLAGS    := -std=c++23 -Wall -Wextra -O2
    LDFLAGS     := -L$(PREFIX)/lib64 -Wl,-rpath,$(PREFIX)/lib64
    # Targets
    TARGET      := hello_print
    SRC         := main.cpp
    all: $(TARGET)
    $(TARGET): $(SRC)
            $(CXX) $(CXXFLAGS) $(SRC) -o $(TARGET) $(LDFLAGS)
    clean:
            rm -f $(TARGET)
    .PHONY: all clean

### Regarding to Python

Here you are a little shared library to be invoked by python on Ubuntu.

Remember to locate your python caller script to reach the shared library.

**testingLib_caller.py**

    import ctypes
    TESTING_LIB = ctypes.CDLL('./build/testingLib.so')
    TESTING_LIB.type_something.argtypes = [ ctypes.c_char_p ]
    TESTING_LIB.type_something.restype = None 
    my_str = ctypes.c_char_p("Testing cross-built shared library".encode('utf-8'))
    TESTING_LIB.type_something(my_str)

**testingLib.hpp**

    #ifndef TESTINGLIB_HPP
    #define TESTINGLIB_HPP
    #ifdef __cplusplus
    extern "C" {
    #endif
    void type_something(char* str);
    #ifdef __cplusplus
    }
    #endif
    #endif // TESTINGLIB_HPP

**CMakeLists.txt**

    cmake_minimum_required(VERSION 3.20)
    set(CMAKE_CXX_COMPILER_WORKS TRUE)
    set(CMAKE_C_COMPILER_WORKS TRUE)
    set(CMAKE_C_COMPILER   "/opt/chaintool/gcc15-ubuntu/bin/gcc")
    set(CMAKE_CXX_COMPILER "/opt/chaintool/gcc15-ubuntu/bin/g++")
    project(testingLib CXX)
    set(SYSROOT "/opt/chaintool/gcc15-almalinux/sysroot")
    set(GCC_LIB "/opt/chaintool/gcc15-almalinux/lib64")
    set(CMAKE_CXX_STANDARD 23)
    # Compiler flags
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} \
        --sysroot=${SYSROOT} \
        -B${SYSROOT}/usr/lib64 \
        -static-libstdc++ -static-libgcc")
    # Linker flags
    set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} \
        -L${SYSROOT}/usr/lib64 \
        -L${GCC_LIB} \
        -Wl,--start-group -lc -lm -lgcc_s -Wl,--end-group \
        ${SYSROOT}/usr/lib64/ld-linux-x86-64.so.2 \
        -Wl,-rpath-link,${SYSROOT}/lib64")
    # Build shared library
    add_library(testingLib SHARED main.cpp)

**main.cpp**

    #include "testingLib.hpp"
    #include <print>
    void type_something(char* str) {
        std::println("Message: {}", str);
    }

### Regarding **TBB**

**main.cpp**

    #include <iostream>
    #include <vector>
    #include <oneapi/tbb.h>
    int main() {
        std::cout << "Hello from TBB! Starting parallel execution..." << std::endl;
        // A simple parallel loop to verify TBB is working
        tbb::parallel_for(tbb::blocked_range<int>(0, 10),
            [](const tbb::blocked_range<int>& r) {
                for (int i = r.begin(); i != r.end(); ++i) {
                    // Using printf because std::cout is not thread-safe and can scramble output
                    printf("TBB Task %d processed by thread\n", i);
                }
            });
        std::cout << "Parallel execution finished successfully." << std::endl;
        return 0;
    }

**Makefile**

    PREFIX      := /opt/toolchain/gcc15-ubuntu
    CXX         := $(PREFIX)/bin/g++
    CXXFLAGS    := -std=c++23 -Wall -Wextra -O3 -I ${PREFIX}/tbb/include
    LDFLAGS     := -L$(PREFIX)/lib64 -Wl,-rpath,$(PREFIX)/lib64 -Wl,--enable-new-dtags
    TARGET      := tbb_example
    SRC         := main.cpp
    all: $(TARGET)
    $(TARGET): $(SRC)
        $(CXX) $(CXXFLAGS) $(SRC) ${PREFIX}/tbb/lib/libtbb.a -o $(TARGET) $(LDFLAGS)
    clean:
        rm -f $(TARGET)
    .PHONY: all clean
### Regarding **Boost**

**main.cpp**

#include <print>
#include <vector>
#include <algorithm>
#include <boost/version.hpp>

    int main() {
        // Check Boost Version using C++23 std::print
        // BOOST_VERSION is formatted as MMmmpp (e.g., 109000 for 1.90.0)
        std::print("Using Boost version: {}.{}.{}\n", 
                   BOOST_VERSION / 100000,          // Major
                   BOOST_VERSION / 100 % 1000,      // Minor
                   BOOST_VERSION % 100);            // Patch
        // Modern C++ logic: Sorting with a lambda
        std::vector<int> nums = {3, 1, 4, 1, 5, 9};
        std::ranges::sort(nums); // Using C++20/23 ranges for brevity
        std::print("Sorted numbers: ");
        for (int n : nums) {
            std::print("{} ", n);
        }
        std::print("\nSuccess: GCC 15.2 and Boost 1.90.0 are working via std::print!\n");
        return 0;
    }

**Makefile**

    PREFIX          = /opt/toolchain/gcc15-ubuntu
    CXX             = $(PREFIX)/bin/g++
    BOOST_ROOT      = $(PREFIX)/boost
    CXXFLAGS        = -std=c++23 -O2 -I$(BOOST_ROOT)/include
    LDFLAGS         = -L$(PREFIX)/lib64 -Wl,-rpath,$(PREFIX)/lib64 -L$(BOOST_ROOT)/lib
    TARGET          = boost_print_test
    SRC             = main.cpp
    all: $(TARGET)
    $(TARGET): $(SRC)
            $(CXX) $(CXXFLAGS) $(SRC) -o $(TARGET) $(LDFLAGS)
    clean:
            rm -f $(TARGET)
    .PHONY: all clean


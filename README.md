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

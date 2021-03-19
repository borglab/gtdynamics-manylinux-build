#!/bin/bash
set -x -e

function retry {
  local retries=$1
  shift

  local count=0
  until "$@"; do
    exit=$?
    wait=$((2 ** $count))
    count=$(($count + 1))
    if [ $count -lt $retries ]; then
      echo "Retry $count/$retries exited $exit, retrying in $wait seconds..."
      sleep $wait
    else
      echo "Retry $count/$retries exited $exit, no more retries left."
      return $exit
    fi
  done
  return 0
}

###################################################
brew update
# brew uninstall bazel
# brew upgrade
brew install wget python cmake || true

CURRDIR=$(pwd)

###################################################
# Build Boost staticly
mkdir -p boost_build
cd boost_build
retry 3 wget https://dl.bintray.com/boostorg/release/1.73.0/source/boost_1_73_0.tar.gz
tar xzf boost_1_73_0.tar.gz
cd boost_1_73_0
./bootstrap.sh --prefix=$CURRDIR/boost_install --with-libraries=serialization,filesystem,thread,system,atomic,date_time,timer,chrono,program_options,regex clang-darwin
./b2 -j$(sysctl -n hw.logicalcpu) cxxflags="-fPIC" runtime-link=static variant=release link=static install

###################################################
# Setup wheelhouse
cd $CURRDIR
mkdir -p $CURRDIR/wheelhouse_unrepaired
mkdir -p $CURRDIR/wheelhouse

###################################################
# Setup Python env variables
ORIGPATH=$PATH

PYTHON_LIBRARY=$(cd $(dirname $0); pwd)/libpython-not-needed-symbols-exported-by-interpreter
touch ${PYTHON_LIBRARY}

declare -a PYTHON_VERSION=( $1 )

# Compile wheels
PYBIN="/usr/local/opt/python@$PYTHON_VERSION/bin"
PYVER_NUM=$($PYBIN/python -c "import sys;print(sys.version.split(\" \")[0])")
PYTHONVER="$(basename $(dirname $PYBIN))"

export PATH=$PYBIN:$PYBIN:/usr/local/bin:$ORIGPATH
"${PYBIN}/pip3" install -r ./requirements.txt
"${PYBIN}/pip3" install delocate

PYTHON_EXECUTABLE=${PYBIN}/python${PYTHON_VERSION}
PYTHON_INCLUDE_DIR=$( find -L ${PYBIN}/../include/ -name Python.h -exec dirname {} \; )
echo ""
echo "PYTHON_EXECUTABLE:${PYTHON_EXECUTABLE}"
echo "PYTHON_INCLUDE_DIR:${PYTHON_INCLUDE_DIR}"
echo "PYTHON_LIBRARY:${PYTHON_LIBRARY}"

###################################################
# Install GTSAM
git clone https://github.com/borglab/gtsam.git -b develop

BUILDDIR="$CURRDIR/gtsam_$PYTHONVER/gtsam_build"
mkdir -p $BUILDDIR
cd $BUILDDIR

cmake $CURRDIR/gtsam -DCMAKE_BUILD_TYPE=Release \
    -DGTSAM_BUILD_TESTS=OFF -DGTSAM_BUILD_UNSTABLE=ON \
    -DGTSAM_USE_QUATERNIONS=OFF \
    -DGTSAM_BUILD_EXAMPLES_ALWAYS=OFF \
    -DGTSAM_PYTHON_VERSION=$PYVER_NUM \
    -DGTSAM_BUILD_WITH_MARCH_NATIVE=OFF \
    -DGTSAM_ALLOW_DEPRECATED_SINCE_V41=OFF \
    -DCMAKE_INSTALL_PREFIX="$BUILDDIR/../gtsam_install" \
    -DBoost_USE_STATIC_LIBS=ON \
    -DBoost_USE_STATIC_RUNTIME=ON \
    -DBOOST_ROOT=$CURRDIR/boost_install \
    -DCMAKE_PREFIX_PATH=$CURRDIR/boost_install/lib/cmake/Boost-1.73.0/ \
    -DBoost_NO_SYSTEM_PATHS=OFF \
    -DBUILD_STATIC_METIS=ON \
    -DGTSAM_BUILD_PYTHON=ON \
    -DPYTHON_EXECUTABLE=${PYTHON_EXECUTABLE}
ec=$?

if [ $ec -ne 0 ]; then
    echo "Error:"
    cat ./CMakeCache.txt
    exit $ec
fi
set -e -x

make -j4 install

###################################################
# Install gtwrap for wrapping
git clone https://github.com/borglab/wrap.git /gtwrap
mkdir -p /gtwrap/build
cd /gtwrap/build
cmake -DWRAP_PYTHON_VERSION=$PYVER_NUM ..
make -j4 && make --silent install
cd /

###################################################
# Build GTDynamics with the wrapper
# Clone GTDynamics
git clone https://varunagrawal:$GTDYNAMICS_PASSWORD@github.com/borglab/gtdynamics.git -b master /gtdynamics

# Set the build directory
BUILDDIR="$CURRDIR/gtdynamics_$PYTHONVER/gtdynamics_build"
mkdir -p $BUILDDIR
cd $BUILDDIR

# Set the C++ compilers
ln -s /opt/rh/devtoolset-7/root/usr/bin/gcc /usr/local/bin/gcc
ln -s /opt/rh/devtoolset-7/root/usr/bin/g++ /usr/local/bin/c++

cmake /gtdynamics \
    -DCMAKE_BUILD_TYPE=Release \
    -DGTDYNAMICS_BUILD_PYTHON=ON \
    -DWRAP_PYTHON_VERSION=$PYVER_NUM \
    -DPYTHON_INCLUDE_DIR=$PYTHON_INCLUDE_DIR \
    -DPYTHON_LIBRARY=$PYTHON_LIBRARY; ec=$?

if [ $ec -ne 0 ]; then
    echo "Error:"
    cat ./CMakeCache.txt
    exit $ec
fi
set -e -x

make -j4 install


###################################################
# Build and fix the wheels
cd python

"${PYBIN}/python${PYTHON_VERSION}" setup.py bdist_wheel
cp ./dist/*.whl $CURRDIR/wheelhouse_unrepaired

# Bundle external shared libraries into the wheels
for whl in $CURRDIR/wheelhouse_unrepaired/*.whl; do
    delocate-listdeps --all "$whl"
    delocate-wheel -w "$CURRDIR/wheelhouse" -v "$whl"
    rm $whl
done

# for whl in /io/wheelhouse/*.whl; do
#     new_filename=$(echo $whl | sed "s#\.none-manylinux_2_24_x86_64\.#.#g")
#     new_filename=$(echo $new_filename | sed "s#\.manylinux_2_24_x86_64\.#.#g") # For 37 and 38
#     new_filename=$(echo $new_filename | sed "s#-none-#-#g")
#     mv $whl $new_filename
# done

# Install packages and test
# for PYBIN in /opt/python/*/bin/; do
#     "${PYBIN}/pip" install python-manylinux-demo --no-index -f /io/wheelhouse
#     (cd "$HOME"; "${PYBIN}/nosetests" pymanylinuxdemo)
# done
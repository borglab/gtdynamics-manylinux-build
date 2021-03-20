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

CURRDIR=$(pwd)

###################################################
# Setup Python env variables
PYTHON_VERSION=$1

PYTHON_MAJOR_VERSION=(${PYTHON_VERSION//./ })
# Need full Python path so that Pybind11 can pick it up correctly
PYTHON_EXECUTABLE=$(python -c "import sys; print(sys.executable)")

PYVER_NUM=$(${PYTHON_EXECUTABLE} -c "import sys;print(sys.version.split(\" \")[0])")
PYTHON_INCLUDE_DIR=$(${PYTHON_EXECUTABLE} -c "from sysconfig import get_paths as gp; print(gp()[\"include\"])")
PYTHON_LIBRARY=$(${PYTHON_EXECUTABLE} -c "import distutils.sysconfig as sysconfig; print(sysconfig.get_config_var(\"LIBDIR\"))")
PYTHONVER=python$PYVER_NUM

echo "PYTHON_EXECUTABLE:${PYTHON_EXECUTABLE}"
echo "PYTHON_INCLUDE_DIR:${PYTHON_INCLUDE_DIR}"
echo "PYTHON_LIBRARY:${PYTHON_LIBRARY}"

pip3 install -r ./requirements.txt
pip3 install delocate

PATH=/Users/$USER/Library/Python/3.8/bin:$PATH

###################################################
# Build Boost staticly
mkdir -p boost_build
cd boost_build
retry 3 wget https://dl.bintray.com/boostorg/release/1.72.0/source/boost_1_72_0.tar.gz
tar xzf boost_1_72_0.tar.gz
cd boost_1_72_0
./bootstrap.sh --with-libraries=serialization,filesystem,thread,system,atomic,date_time,timer,chrono,program_options,regex clang-darwin
./b2 -j$(sysctl -n hw.logicalcpu) cxxflags="-fPIC" runtime-link=static variant=release link=static install

###################################################
# Install GTSAM
git clone https://github.com/borglab/gtsam.git -b develop $CURRDIR/gtsam

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
    -DBoost_USE_STATIC_LIBS=ON \
    -DBoost_USE_STATIC_RUNTIME=ON \
    -DBOOST_ROOT=$CURRDIR/boost_install \
    -DCMAKE_PREFIX_PATH=$CURRDIR/boost_install/lib/cmake/Boost-1.72.0/ \
    -DBoost_NO_SYSTEM_PATHS=OFF \
    -DBUILD_STATIC_METIS=ON \
    -DGTSAM_BUILD_PYTHON=ON \
    -DGTSAM_WITH_TBB=OFF \
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
git clone https://github.com/borglab/wrap.git $CURRDIR/gtwrap
mkdir -p $CURRDIR/gtwrap/build
cd $CURRDIR/gtwrap/build
cmake -DWRAP_PYTHON_VERSION=$PYVER_NUM ..
make -j4 && make --silent install
cd $CURRDIR


###################################################
# Build GTDynamics with the wrapper
# Clone GTDynamics
git clone https://varunagrawal:$GTDYNAMICS_PASSWORD@github.com/borglab/gtdynamics.git -b master $CURRDIR/gtdynamics

# Set the build directory
BUILDDIR="$CURRDIR/gtdynamics_$PYTHONVER/gtdynamics_build"
mkdir -p $BUILDDIR
cd $BUILDDIR

# Install SDFormat8
brew tap osrf/simulation
brew install sdformat8

cmake $CURRDIR/gtdynamics \
    -DCMAKE_BUILD_TYPE=Release \
    -DGTDYNAMICS_BUILD_PYTHON=ON \
    -DBoost_USE_STATIC_LIBS=ON \
    -DBoost_USE_STATIC_RUNTIME=ON \
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
# Setup wheelhouse
mkdir -p $CURRDIR/wheelhouse_unrepaired
mkdir -p $CURRDIR/wheelhouse

###################################################
# Build and fix the wheels
cd python

${PYTHON_EXECUTABLE} setup.py bdist_wheel
cp ./dist/*.whl $CURRDIR/wheelhouse_unrepaired/

# Bundle external shared libraries into the wheels
for whl in $CURRDIR/wheelhouse_unrepaired/*.whl; do
    delocate-listdeps --all "$whl"
    delocate-wheel -w "$CURRDIR/wheelhouse" -v "$whl"
    rm $whl
done

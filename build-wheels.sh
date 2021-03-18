#!/bin/bash

CURRDIR=$(pwd)

# Install latest version of GTSAM
add-apt-repository -y ppa:borglab/gtsam-develop
apt-get -y update
apt-get install -y libgtsam-dev libgtsam-unstable-dev

# Clone GTDynamics
git clone https://github.com/borglab/gtdynamics.git -b master /gtdynamics

# Set the build directory
BUILDDIR="/io/gtdynamics_build"

# FIX auditwheel
# https://github.com/pypa/auditwheel/issues/136
echo /opt/_internal/*/*/*/*/auditwheel
cd /opt/_internal/tools/lib64/python3.7/site-packages/auditwheel
patch -p2 < /io/auditwheel.txt
cd $BUILDDIR

PYBIN="/opt/python/$PYTHON_VERSION/bin"
PYVER_NUM=$($PYBIN/python -c "import sys;print(sys.version.split(\" \")[0])")
PYTHONVER="$(basename $(dirname $PYBIN))"

export PATH=$PYBIN:$PATH

${PYBIN}/pip install -r /io/requirements.txt

PYTHON_EXECUTABLE=${PYBIN}/python
# We use distutils to get the include directory and the library path directly from the selected interpreter
# We provide these variables to CMake to hint what Python development files we wish to use in the build.
PYTHON_INCLUDE_DIR=$(${PYTHON_EXECUTABLE} -c "from distutils.sysconfig import get_python_inc; print(get_python_inc())")
PYTHON_LIBRARY=$(${PYTHON_EXECUTABLE} -c "import distutils.sysconfig as sysconfig; print(sysconfig.get_config_var('LIBDIR'))")

echo ""
echo "PYTHON_EXECUTABLE:${PYTHON_EXECUTABLE}"
echo "PYTHON_INCLUDE_DIR:${PYTHON_INCLUDE_DIR}"
echo "PYTHON_LIBRARY:${PYTHON_LIBRARY}"
echo ""

cmake /gtdynamics -DCMAKE_BUILD_TYPE=Release \
    -DGTDYNAMICS_BUILD_PYTHON=ON; ec=$?

if [ $ec -ne 0 ]; then
    echo "Error:"
    cat ./CMakeCache.txt
    exit $ec
fi
set -e -x

make -j$(nproc) install

mkdir -p /io/wheelhouse

# "${PYBIN}/pip" wheel . -w "/io/wheelhouse/"
cd python

"${PYBIN}/python" setup.py bdist_wheel --python-tag=$PYTHONVER --plat-name=$PLAT
# cp ./dist/*.whl /io/wheelhouse/

# Bundle external shared libraries into the wheels
for whl in ./dist/*.whl; do
    auditwheel repair "$whl" -w /io/wheelhouse/
done

for whl in /io/wheelhouse/*.whl; do
    new_filename=$(echo $whl | sed "s#\.none-manylinux2014_x86_64\.#.#g")
    new_filename=$(echo $new_filename | sed "s#\.manylinux2014_x86_64\.#.#g") # For 37 and 38
    new_filename=$(echo $new_filename | sed "s#-none-#-#g")
    mv $whl $new_filename
done

# Install packages and test
# for PYBIN in /opt/python/*/bin/; do
#     "${PYBIN}/pip" install python-manylinux-demo --no-index -f /io/wheelhouse
#     (cd "$HOME"; "${PYBIN}/nosetests" pymanylinuxdemo)
# done

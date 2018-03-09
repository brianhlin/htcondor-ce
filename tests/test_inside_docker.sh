#!/bin/bash -xe

function run_osg_tests {
    # Source repo version
    git clone https://github.com/opensciencegrid/osg-test.git
    pushd osg-test
    git rev-parse HEAD
    make install
    popd

    # Ok, do actual testing
    set +e # don't exit immediately if osg-test fails
    echo "------------ OSG Test --------------"
    osg-test -vad --hostcert --no-cleanup
    test_exit=$?
    set -e
}

function run_integration_tests {
    useradd -m cetest

    # create host/user certificates
    test_user=cetest
    osg-ca-generator --host --user $test_user --pass $test_user

    # add the host subject DN to the top of the condor_mapfile
    host_dn=$(python -c "import cagen; print cagen.certificate_info('/etc/grid-security/hostcert.pem')[0]")
    host_dn=${host_dn//\//\\/} # escape all forward slashes
    entry="GSI \"${host_dn}\" $(hostname --long)@daemon.opensciencegrid.org"
    ce_mapfile='/etc/condor-ce/condor_mapfile'
    tmp_mapfile=$(mktemp)
    echo $entry | cat - $ce_mapfile > $tmp_mapfile && mv $tmp_mapfile $ce_mapfile

    yum install -y sudo # run tests as non-root user

    echo "------------ Integration Test --------------"
    set +e
    service condor-ce start
    service condor start

    # wait until the schedd is ready before submitting a job
    timeout 30 bash -c 'until (condor_ce_q); do sleep 0.5; done' > /dev/null 2>&1

    condor_ce_status -any
    condor_ce_q

    # submit test job as a normal user
    sudo --user $test_user /bin/sh -c "echo $test_user | voms-proxy-init -pwstdin"
    sudo --user $test_user condor_ce_trace -d $(hostname --long)
    set -e
    test_exit=$?
}

function debug_info {
    # Some simple debug files for failures.
    openssl x509 -in /etc/grid-security/hostcert.pem -noout -text
    echo "------------ CE Logs --------------"
    cat /var/log/condor-ce/MasterLog
    cat /var/log/condor-ce/CollectorLog
    cat /var/log/condor-ce/SchedLog
    cat /var/log/condor-ce/JobRouterLog
    echo "------------ HTCondor Logs --------------"
    cat /var/log/condor/MasterLog
    cat /var/log/condor/CollectorLog
    cat /var/log/condor/SchedLog
    condor_config_val -dump
}

OS_VERSION=$1
BUILD_ENV=$2

ls -l /home

# Clean the yum cache
yum -y clean all
yum -y clean expire-cache

# First, install all the needed packages.
rpm -Uvh https://dl.fedoraproject.org/pub/epel/epel-release-latest-${OS_VERSION}.noarch.rpm

# Broken mirror?
echo "exclude=mirror.beyondhosting.net" >> /etc/yum/pluginconf.d/fastestmirror.conf

yum -y install yum-plugin-priorities
rpm -Uvh https://repo.opensciencegrid.org/osg/3.4/osg-3.4-el${OS_VERSION}-release-latest.rpm
yum -y install rpm-build gcc gcc-c++ boost-devel cmake git tar gzip make autotools

# Prepare the RPM environment
mkdir -p /tmp/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
if [ "$BUILD_ENV" == 'osg' ]; then
   cat >> /etc/rpm/macros.dist << EOF
%dist .osg.el${OS_VERSION}
%osg 1
EOF
fi

cp htcondor-ce/rpm/htcondor-ce.spec /tmp/rpmbuild/SPECS
package_version=`grep Version htcondor-ce/rpm/htcondor-ce.spec | awk '{print $2}'`
pushd htcondor-ce
git archive --format=tar --prefix=htcondor-ce-${package_version}/ HEAD  | gzip >/tmp/rpmbuild/SOURCES/htcondor-ce-${package_version}.tar.gz
popd

# Build the RPM
rpmbuild --define '_topdir /tmp/rpmbuild' -ba /tmp/rpmbuild/SPECS/htcondor-ce.spec

# After building the RPM, try to install it
# Fix the lock file error on EL7.  /var/lock is a symlink to /var/run/lock
mkdir -p /var/run/lock

RPM_LOCATION=/tmp/rpmbuild/RPMS/noarch
yum localinstall -y $RPM_LOCATION/htcondor-ce-${package_version}* $RPM_LOCATION/htcondor-ce-client-* $RPM_LOCATION/htcondor-ce-condor-* $RPM_LOCATION/htcondor-ce-view-* --enablerepo=osg-development

# Run unit tests
pushd htcondor-ce/tests/
python run_tests.py
popd

# HTCondor really, really wants a domain name.  Fake one.
sed /etc/hosts -e "s/`hostname`/`hostname`.unl.edu `hostname`/" > /etc/hosts.new
/bin/cp -f /etc/hosts.new /etc/hosts

# Install tooling for creating test certificates
git clone https://github.com/opensciencegrid/osg-ca-generator.git
pushd osg-ca-generator
git rev-parse HEAD
make install
popd

# Bind on the right interface and skip hostname checks.
cat << EOF > /etc/condor/config.d/99-local.conf
NETWORK_INTERFACE=eth0
GSI_SKIP_HOST_CHECK=true
SCHEDD_DEBUG=\$(SCHEDD_DEBUG) D_FULLDEBUG
SCHEDD_INTERVAL=1
SCHEDD_MIN_INTERVAL=1
EOF
cp /etc/condor/config.d/99-local.conf /etc/condor-ce/config.d/99-local.conf

# Reduce the trace timeouts
export _condor_CONDOR_CE_TRACE_ATTEMPTS=60

if [ "$BUILD_ENV" == 'osg' ]; then
    run_osg_tests
else
    run_integration_tests
fi

debug_info

# Verify preun/postun in the spec file
yum remove -y 'htcondor-ce*'

exit $test_exit

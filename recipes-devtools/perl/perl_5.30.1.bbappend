# This bbappend is to support the of vcc package mode process
#
# The perl-rdepends.txt file is required by the do_package task and
# this file is expected to be present in the WORKDIR when the do_package task
# is performed. This file is usually stored along with the recipe and patch files
# and in case of a normal build this gets copied to the WORKDIR by the do_unpack
# task. Since in vcc package mode, the do_unpack is not active, this file needs
# to be copied to the WORKDIR as part of the do_vcctask so that the do_package
# task can find it in the expected location.

do_vccprocess[postfuncs] += " copy_perl_rdepends_file "
copy_perl_rdepends_file () {
    cp -f ${FILE_DIRNAME}/files/perl-rdepends.txt ${WORKDIR}/
}

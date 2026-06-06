set tmpdir [expr {[info exists ::env(TMP)] ? $::env(TMP) : "/tmp"}]
puts "SETTING CONFIGURATION"
dbset db maria
dbset bm TPC-C

diset connection maria_host 127.0.0.1
diset connection maria_port 3307
diset connection maria_socket null

diset tpcc maria_user root
diset tpcc maria_pass maria
diset tpcc maria_dbase tpcc
diset tpcc maria_driver timed
diset tpcc maria_rampup 2
diset tpcc maria_duration 10
diset tpcc maria_allwarehouse true
diset tpcc maria_timeprofile true

loadscript
puts "TEST STARTED"
vuset vu 16
vucreate
tcstart
tcstatus
set jobid [ vurun ]
vudestroy
tcstop
puts "TEST COMPLETE"
set of [ open $tmpdir/maria_tprocc w ]
puts $of $jobid
close $of

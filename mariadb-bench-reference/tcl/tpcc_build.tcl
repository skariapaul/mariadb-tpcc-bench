puts "SETTING CONFIGURATION"
dbset db maria
dbset bm TPC-C

diset connection maria_host 127.0.0.1
diset connection maria_port 3307
diset connection maria_socket null

set vu 8
set warehouse 64
diset tpcc maria_count_ware $warehouse
diset tpcc maria_num_vu $vu
diset tpcc maria_user root
diset tpcc maria_pass maria
diset tpcc maria_dbase tpcc
diset tpcc maria_storage_engine innodb
if { $warehouse >= 200 } {
diset tpcc maria_partition true
        } else {
diset tpcc maria_partition false
        }
puts "SCHEMA BUILD STARTED"
buildschema
puts "SCHEMA BUILD COMPLETED"

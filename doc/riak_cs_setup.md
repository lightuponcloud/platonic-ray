## Why Riak CS

It is compatible with AWS S3 protocol, a defacto standard in industry.
It means it can work with Amazon S3 as well as with other providers.
I used Riak CS as a main storage backend, as it is very predictable on resource consumption.
It has recovery tools, scales automatically, it can store files > 5 TB and has multi-datacenter bidirectional replication.
It was built using the latest academic research in the area of distributed systems.

The list of companies who use Riak CS, -- object storage software, used with DubStack:
"Yahoo! Japan", Booking.com, UK National Health System, TI Tokyo, Bloomberg, Klarna, 
Bet365, EE.co.uk, Bleacher Report, Derivco, etc.


# How to install Riak CS ?

## 1. Install the following packages
```
build-essential make autoconf libncurses5-dev libkrb5-dev libssl-dev
libpam0g-dev default-jre git curl unixodbc-dev bison flex ed
libwxgtk3.0-dev dctrl-tools xsltproc libgl1-mesa-dev libgl-dev
libglu1-mesa-dev libglu-dev libsctp-dev libxml2-utils fop default-jdk
```

## 2. Use "kerl" to download compatible version of Erlang
```sh
https://github.com/kerl/kerl.git
./kerl build git git://github.com/basho/otp.git OTP_R16B02_basho8 R16B02-basho8
./kerl install R16B02-basho8 ~/erlang/R16B02-basho8 
. ~/erlang/R16B02-basho8/activate
```

## 3. Build Riak CS dependencies

Riak CS dependencies: ``Riak`` a key/value storage and ``Stanchion``,
wchich makes sure all entities are globally unique.

#### 3.1. You need to download Riak from Github
```sh
git clone -b 2.1.1 https://github.com/basho/riak.git
```

Branch 2.1.1 is the last version, compatible with stable Stanchion and Riak CS at the moment ( 09/01/2017 ).

#### 3.2. Then get Stanchion
```sh
git clone -b 2.1 https://github.com/basho/stanchion.git
```

#### 3.3. And finally get Riak CS
```sh
git clone -b 2.1 https://github.com/basho/riak_cs.git
```

## 4. Build Riak
Execute
```sh
make rel
```

Use the same command for building Riak CS and Stanchion.

## 5. Edit Riak configuration files

advanced.config:
```
    [
     {riak_kv, [
     {add_paths, ["/home/username/src/riak/riak_cs/ebin"]},
     {storage_backend, riak_cs_kv_multi_backend},
     {multi_backend_prefix_list, [{<<"0b-">>, be_blocks}]},
     {multi_backend_default, be_default},
     {multi_backend, [
     {be_default, riak_kv_eleveldb_backend, [
     {total_leveldb_mem_percent, 30},
     {data_root, "/home/username/var/lib/riak/leveldb"}
     ]},
     {be_blocks, riak_kv_bitcask_backend, [
     {data_root, "/home/username/var/lib/riak/bitcask"}
     ]}
     ]}
     ]}
    ].
```

riak.conf:
```
    nodename = riak@127.0.0.1
    distributed_cookie = riak
    listener.http.internal = 127.0.0.1:8098
    listener.protobuf.internal = 127.0.0.1:8087
    listener.https.internal = 127.0.0.1:18098
    buckets.default.allow_mult = true
```

## 6. Edit Riak CS configuration files.

riak-cs.conf:
```
    listener = 0.0.0.0:8080
    riak_host = 127.0.0.1:8087
    stanchion_host = 127.0.0.1:8085
    stanchion.ssl = off
    anonymous_user_creation = on
    admin.listener = 127.0.0.1:8000
    root_host = s3.amazonaws.com
    nodename = riak-cs@127.0.0.1
    distributed_cookie = riak
```

advanced.config:
```
    [
     {riak_cs,
     [
     {auth_v4_enabled, true},
     {enforce_multipart_part_size, false}
     ]}
    ].
```

## 7. Start Riak, Stanchion and then Riak CS ( order is important )

```sh
./riak/rel/riak/bin/riak start
./stanchion/rel/stanchion/bin/stanchion start
./riak_cs/rel/riak_cs/bin/riak start
```

## 8. Add admin user
```sh
curl -X POST http://127.0.0.1:8000/riak-cs/user \
    -H 'Content-Type: application/json' \
    --data '{"email":"admin@example.com", "name":"admin"}' 
```

You should receive the following response:
```json
    {
    "email":"vitalii.boiko@evolute.ch",
    "display_name": "vitalii.boiko",
    "name": "admin",
    "key_id": "6DAERANB3MA8TCX6XIMR",
    "key_secret": "qzkhdAXunZezfVAuWoxt6yFVVDqe32a4zfy27g",
    "id": "029ee1878f42fa49045d432fa12c6f4e902dee4bca747e4f59daf6bc2d9d3e19",
    "status": "enabled"
    }
```

##9. Turn off "anonymous_user_creation" flag in riak_cs.conf
```
    anonymous_user_creation = off
    And specify admin identifier (riak_cs.conf and stanchion.conf files):
    admin.key = 6DAERANB3MA8TCX6XIMR
    You can also turn on Riak control panel in riak.conf:
    riak_control = on
    riak_control.auth.mode = userlist
    riak_control.auth.user.admin.password = qzkhdAXunZezfVAuWoxt6yFVVDqe32a4zfy27g
```

## 10. Change limits in /etc/security/limits.conf
```
    root soft nofile 65536
    root hard nofile 65536
    myuser soft nofile 65536
    myuser hard nofile 65536
```

## 11. Restart Riak, Stanchion and Riak CS.

Riak CS is ready for uploading objects.
You can use s3cmd command-line tool for browsing.

~/.s3cfg:
```
access_key = 6DAERANB3MA8TCX6XIMR
...
proxy_host = 127.0.0.1
proxy_port = 8080
...
secret_key = qzkhdAXunZezfVAuWoxt6yFVVDqe32a4zfy27g
```

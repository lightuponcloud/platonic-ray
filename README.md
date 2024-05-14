# DubStack

[![SWUbanner](https://raw.githubusercontent.com/vshymanskyy/StandWithUkraine/main/banner2-direct.svg)](https://github.com/vshymanskyy/StandWithUkraine/blob/main/docs/README.md)

This middleware is used to synchronize Riak CS contents with filesystem. Also it provides web UI for browsing files.

![Screenshot](doc/dubstack.png)

## What it can do

1. **File Synchronization**

    DubStack is a server side of team collagoration apps. There are Windows, Android and IOS apps.
    Windows app synchronizes files in background and allows file **lock**/**unlock**,
    **delete**/**undelete**, **copy**/**move**, differential sync and **automated conflict resolution**.

2. **Thumbnails, watermarks**

    Thumbnails are generated on demand by dedicated gen_server process.
    It applies watermark on thumbnails, if watermark.png found in bucket.

3. File and directory sharing
    This feature can be used for selling digital content.

4. **Action log and changelog**

    It records history of upload, copy, move, rename and delete operations.

5. **Multi-tenancy**

    Objects are stored in "buckets" with names like "the-tenant-group-res"
    Only users from tenant's group can access that bucket.

6. **IOS and Windows apps**

    You can manage objects, users, their groups and tenants using Web UI browser.
    You can manage objects using IOS App.

7. **Oauth2**
    Support of KeyCloak authentication / authorization.



## Why Erlang
    Erlang applications are known working for tens of years without intervention.
    For example in Ericsson telecommunication hardware.
    This application is written in Erlang. Its processes are restarted automatically in case of errors.

## Why Riak CS

It is S3 compatible. It means it can work with Amazon S3 as well as with Riak CS.
I used Riak CS as a main storage backend, as it is very predictable on resource consumption.
It has recovery tools, scales automatically, it can store files > 5 TB and has multi-datacenter bidirectional replication.
It was built using the latest academic research in the area of distributed systems.

The list of companies who use Riak CS, -- object storage software, used with DubStack:
"Yahoo! Japan", Booking.com, UK National Health System, TI Tokyo, Bloomberg, Klarna, 
Bet365, EE.co.uk, Bleacher Report, Derivco, etc.


## Advantages of DubStack

### 1. Simple Architecture

Erlang applications are much easier to maintain.

Typical setup:

![Typical web application on Python](doc/ordinary_diagram.png)

Erlang web application:

![Erlang Application](doc/erlang_diagram.png)



### 2. Multi-tenant Setup

DubStack creates buckets with names of the following format.
```
<bucket prefix>-<user id>-<tenant id>-<bucket type>"
```
**bucket prefix** : A short string that can be used by reverse-proxy, such as Nginx:
```
location /the- {
    proxy_pass_header Authorization;
    ...
}
```

**user id** : Short string, that identifies User bucket created for.

**tenant id** : Short identifier of tenant ( aka project ).

**bucket type** : By default "res", -- restricted. Only users within the same tenant
can access restricted buckets.


## 3. UI

Action Log

![Action Log](doc/action_log.png)

User Management Interface

![User Management](doc/admin_tenants.png)

![User Record Editing Dialog](doc/admin_user_edit.png)


## 4. API

[See API reference](API.md)


## Installation

### Dependencies

* Erlang >= 23, < 25

* coreutils ( ``"/usr/bin/head"``, ``/bin/mktemp`` commands )

* imagemagick-6.q16

* libmagickwand-dev


#### 1. Build Riak CS

[See Riak CS Installation Manual](/doc/riak_cs_setup.md) for installation and configuration instructions.

#### 2. Build DubStack

Clone this repository and execute the following commands.
```sh
make fetch-deps
make deps
make
```

In order to use specific version of erlang, you should set environment variables 
*C_INCLUDE_PATH* and *LIBRARY_PATH*. For example:
```sh
export C_INCLUDE_PATH=/usr/lib/erlang/usr/include:/usr/include/ImageMagick-6:/usr/include/x86_64-linux-gnu/ImageMagick-6
export LIBRARY_PATH=/usr/lib/erlang/usr/lib:/usr/include/ImageMagick-6
```

The following imagemagic packages are required:
imagemagick-6.q16 libmagickcore-6-arch-config libmagickwand-6.q16-dev

#### 3. Edit configuration files

You need to change ``riak_api_config`` in ``include/riak.hrl``.
Locate ``riak-cs.conf`` in Riak CS directory. Copy ``admin.key`` value from ``riak-cs.conf``
and paste it to ``access_key_id`` in ``riak_api_config``.

Then locate ``riak.conf`` in Riak directory and place value of ``riak_control.auth.user.admin.password``
to ``include/riak.hrl``, to the ``secret_access_key`` option.

In order to add first user, authentication should be temporary disabled.

Edit file ``include/riak.hrl`` and set ``ANONYMOUS_USER_CREATION`` to ``true``.

Then start DubStack by executing ``make run``.

#### 4. Add users

Create the first ``tenant``:
```sh
curl -X POST "http://127.0.0.1/riak/admin/tenants/" \
    -H "accept: application/json" \
    -H "Content-Type: application/json" \
    -d "{ \"name\": \"My Brand\", \"enabled\": \"true\", \"groups\": \"Engineers, Another Group\" }"
```

**Expected Response** :
```json
{
   "id":"mybrand",
   "name":"My Brand",
   "enabled":"true",
   "groups":[
      {
         "id":"engineers",
         "name":"Engineers"
      },
      {
         "id":"anothergroup",
         "name":"Another Group"
      }
   ]
}
```

Add the first ``user``:
```sh
curl -X POST "http://127.0.0.1/riak/admin/mybrand/users/" \
    -H "accept: application/json" \
    -H "Content-Type: application/json" \
    -d "{ \"name\": \"Joe Armstrong\", \"login\": \"ja@example.com\", \"password\": \"secret\", \"enabled\": \"true\", \"staff\": \"true\", \"groups\": \"engineers, anothergroup\" }"
```

**Expected Response** :
```json
{
   "id":"1fc069d1c19b47b4454f5673b25b653c",
   "name":"Joe Armstrong",
   "tenant_id":"mybrand",
   "tenant_name":"My Brand",
   "tenant_enabled":"true",
   "login":"ja@example.com",
   "enabled":"true",
   "staff":"true",
   "groups":[
      {
         "id":"engineers",
         "name":"Engineers",
         "available_bytes":-1,
         "bucket_id":"the-mybrand-engineers-res",
         "bucket_suffix":"res"
      },
      {
         "id":"anothergroup",
         "name":"Another Group",
         "available_bytes":-1,
         "bucket_id":"the-mybrand-anothergroup-res",
         "bucket_suffix":"res"
      }
   ]
}
```

Now you should change ``general_settings`` in ``include/general.hrl`` and set
``domain`` option to IP address or domain name that you use.
Otherwise login won't work.

Finally you should set ``ANONYMOUS_USER_CREATION`` to ``false``
and restart DubStack. 

You can login now using credentials of staff user that you have just created.
Staff user has permission to add other users.




# Contributing

Please feel free to send me bug reports, possible securrity issues, feature requests or questions.

# DubStack

[![SWUbanner](https://raw.githubusercontent.com/vshymanskyy/StandWithUkraine/main/banner2-direct.svg)](https://github.com/vshymanskyy/StandWithUkraine/blob/main/docs/README.md)

This middleware is used to synchronize AWS S3 compatible storage objects with filesystem. Also it provides web UI for browsing files.

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

7. **API**
    Easy to embed into your application for file sharing.
    [See API reference](API.md)


## Why Erlang
    Erlang applications are very resilient: processes are restarted as soon as they terminate.
    Excellent inter-node communication.
    Code is running inside Erlang Virtual Machine (BEAM), isolating segment of code and segment of data for security purpose.


## Advantages of DubStack

### 1. Simple Architecture

![DubStack Application](cdk/aws_architecture.png)


### 2. Multi-tenancy

DubStack supports multiple tenants per installation


### 3. Low Operative Costs

DubStack is very cheap to run on AWS s3 compatible service. It requires minimum maintenance.



## Installation

### AWS Installation

[See CDK documentation](cdk/README.md)


### Local Installation

You will need the followingDependencies

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

In order to use specific version of Erlang, you should set environment variables 
*C_INCLUDE_PATH* and *LIBRARY_PATH*. For example:
```sh
export C_INCLUDE_PATH=/usr/lib/erlang/usr/include:/usr/include/ImageMagick-6:/usr/include/x86_64-linux-gnu/ImageMagick-6
export LIBRARY_PATH=/usr/lib/erlang/usr/lib:/usr/include/ImageMagick-6
```

The following imagemagic packages are required:
imagemagick-6.q16 libmagickcore-6-arch-config libmagickwand-6.q16-dev

#### 3. Edit configuration files

You need to change ``api_config`` in ``include/storage.hrl``.
Locate ``riak-cs.conf`` in Riak CS directory. Copy ``admin.key`` value from ``riak-cs.conf``
and paste it to ``access_key_id`` in ``riak_api_config``.

Then locate ``riak.conf`` in Riak directory and place value of ``riak_control.auth.user.admin.password``
to ``include/riak.hrl``, to the ``secret_access_key`` option.

In order to add first user, authentication should be temporary disabled.

Then start DubStack by executing ``make run``.


Now you should change ``general_settings`` in ``include/general.hrl`` and set
``domain`` option to IP address or domain name that you use.
Otherwise login won't work.

You can login now using credentials of staff user that you have just created.
Staff user has permission to add other users.



# Contributing

Please feel free to send me bug reports, possible securrity issues, feature requests or questions.

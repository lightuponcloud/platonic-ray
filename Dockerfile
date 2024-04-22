FROM erlang:23-alpine

RUN mkdir /middleware
WORKDIR /middleware

COPY . /middleware

ENV C_INCLUDE_PATH=/usr/include:/usr/include/ImageMagick-6:/usr/include/x86_64-linux-gnu/ImageMagick-6
ENV LIBRARY_PATH=/usr/lib:/usr/include/ImageMagick-6

RUN apk add --no-cache make curl git alpine-sdk sed sqlite-dev

RUN curl -O https://erlang.mk/erlang.mk

RUN /usr/bin/make fetch-deps

RUN mv /middleware/deps/jsx/Makefile.orig.mk /middleware/deps/jsx/Makefile
RUN mv /middleware/deps/lager/Makefile.orig.mk /middleware/deps/lager/Makefile
RUN mv /middleware/deps/erlydtl/Makefile.orig.mk /middleware/deps/erlydtl/Makefile
RUN sed -i s/.\\/rebar/rebar3/g /middleware/deps/lager/Makefile
RUN sed -i s/rebar\ /rebar3\ /g /middleware/deps/jsx/Makefile

RUN cd /middleware/deps/lager && rebar3 get-deps && rebar3 compile

RUN /usr/bin/make deps

RUN /usr/bin/make rel

# Expose relevant ports
EXPOSE 8081

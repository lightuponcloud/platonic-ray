FROM erlang:23-alpine

RUN mkdir /middleware
WORKDIR /middleware

COPY c_src /middleware/c_src
COPY include /middleware/include
COPY priv /middleware/priv
COPY rel /middleware/rel
COPY src /middleware/src
COPY templates /middleware/templates
COPY Makefile /middleware/Makefile
COPY erlang.mk /middleware/erlang.mk
COPY relx.config /middleware/relx.config


ENV C_INCLUDE_PATH=/usr/lib:/usr/lib/erlang/usr/include:/usr/include/ImageMagick-6
ENV LIBRARY_PATH=/usr/lib:/usr/lib/erlang/usr/include:/usr/include/ImageMagick-6

RUN apk add --no-cache make curl git alpine-sdk sed sqlite-dev imagemagick6-dev imagemagick6 erlang-dev

RUN curl -O https://erlang.mk/erlang.mk

RUN /usr/bin/make deps
RUN /usr/bin/make rel

EXPOSE 8081

CMD ["/middleware/_rel/middleware/bin/middleware", "foreground"]

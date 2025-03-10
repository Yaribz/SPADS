FROM ubuntu:rolling

RUN apt-get update \
 && apt-get upgrade -y \
 && apt-get install --no-install-recommends -y \
   curl \
   perl \
   swig \
   g++ \
   ca-certificates \
   libcurl4 \
   libsdl2-2.0-0 \
   net-tools \
   python \
   python-pycurl \
 && apt-get autoremove \
 && rm -rf /var/run/apt \
 && useradd -m spads \
 && chown -R spads /opt


COPY scripts/*.sh /opt/
RUN mkdir -p /opt/spads \
 && cd /opt/spads \
 && curl -L -O http://planetspads.free.fr/spads/installer/spadsInstaller.tar \
 && tar -xvf spadsInstaller.tar \
 && chmod +x /opt/*.sh \
 && chown -R spads /opt/spads

USER spads
WORKDIR /opt/spads/

RUN /opt/install-spads.sh


ENTRYPOINT [ "/opt/spads-entrypoint.sh" ]
CMD [ "/opt/run-spads.sh" ]


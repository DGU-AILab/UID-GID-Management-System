FROM mysql:8.4

# Copy initialization SQL script
COPY ./init.sql /docker-entrypoint-initdb.d/

# Expose MySQL port
EXPOSE 3306
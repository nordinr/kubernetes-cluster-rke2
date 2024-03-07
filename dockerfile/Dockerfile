# Use the official WordPress image as the base image
FROM wordpress:6.4.2-php8.1-apache

# Add any additional customization or configurations here

# Example: Install additional PHP extensions
RUN docker-php-ext-install mysqli pdo pdo_mysql
# Example: Copy custom configuration files
# COPY custom-php.ini /usr/local/etc/php/conf.d/custom-php.ini

# Example: Set environment variables
# ENV MY_CUSTOM_VARIABLE=value

# Start the WordPress container entrypoint
USER www-data

# Optionally, specify the default command to run (e.g., Apache web server)
CMD ["apache2-foreground"]

// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "controllers"
import "@hotwired/turbo-rails"
// Must come after turbo-rails: it reads the global Turbo that import installs.
import "turbo_stream_actions"

#!/usr/bin/ruby

require 'rubygems'
gem 'google-api-client', '>0.7'
require 'google/api_client'
require 'google/api_client/client_secrets'
require 'google/api_client/auth/file_storage'
require 'google/api_client/auth/installed_app'
require 'trollop'
require 'google/api_client'
require 'google/api_client/client_secrets'
require 'json'
require 'launchy'
require 'thin'

RESPONSE_HTML = <<stop
<html>
  <head>
    <title>OAuth 2 Flow Complete</title>
  </head>
  <body>
    You have successfully completed the OAuth 2 flow. Please close this browser window and return to your program.
  </body>
</html>
stop

FILE_POSTFIX = 'client_secret_516051658702-o9o3fvmnl3gkq3l95aere6uhd4fjjsnh.apps.googleusercontent.com.json'

# Small helper for the sample apps for performing OAuth 2.0 flows from the command
# line. Starts an embedded server to handle redirects.
class CommandLineOAuthHelper

  def initialize(scope)
    credentials = Google::APIClient::ClientSecrets.load
    @authorization = Signet::OAuth2::Client.new(
      :authorization_uri => credentials.authorization_uri,
      :token_credential_uri => credentials.token_credential_uri,
      :client_id => credentials.client_id,
      :client_secret => credentials.client_secret,
      :redirect_uri => credentials.redirect_uris.first,
      :scope => scope
    )
  end

  # Request authorization. Checks to see if a local file with credentials is present, and uses that.
  # Otherwise, opens a browser and waits for response, then saves the credentials locally.
  def authorize
    credentialsFile = FILE_POSTFIX

    if File.exist? credentialsFile
      File.open(credentialsFile, 'r') do |file|
        credentials = JSON.load(file)
        @authorization.access_token = credentials['access_token']
        @authorization.client_id = credentials['client_id']
        @authorization.client_secret = credentials['client_secret']
        @authorization.refresh_token = credentials['refresh_token']
        @authorization.expires_in = (Time.parse(credentials['token_expiry']) - Time.now).ceil
        if @authorization.expired?
          @authorization.fetch_access_token!
          save(credentialsFile)
        end
      end
    else
      auth = @authorization
      url = @authorization.authorization_uri().to_s
      server = Thin::Server.new('0.0.0.0', 8081) do
        run lambda { |env|
          # Exchange the auth code & quit
          req = Rack::Request.new(env)
          auth.code = req['code']
          auth.fetch_access_token!
          server.stop()
          [200, {'Content-Type' => 'text/html'}, RESPONSE_HTML]
        }
      end

      Launchy.open(url)
      server.start()

      save(credentialsFile)
    end

    return @authorization
  end

  def save(credentialsFile)
    File.open(credentialsFile, 'w', 0600) do |file|
      json = JSON.dump({
        :access_token => @authorization.access_token,
        :client_id => @authorization.client_id,
        :client_secret => @authorization.client_secret,
        :refresh_token => @authorization.refresh_token,
        :token_expiry => @authorization.expires_at
      })
      file.write(json)
    end
  end
end

Faraday.default_adapter = :httpclient

# A limited OAuth 2 access scope that allows for uploading files, but not other
# types of account access.
YOUTUBE_UPLOAD_SCOPE = 'https://www.googleapis.com/auth/youtube.upload'
YOUTUBE_API_SERVICE_NAME = 'youtube'
YOUTUBE_API_VERSION = 'v3'



def get_authenticated_service
  e= CommandLineOAuthHelper.new"https://www.googleapis.com/auth/youtube.upload"
  e.authorize
  #e = CommandLineOAuthHelper.new
  #e.authorize
  client = Google::APIClient.new(
    :application_name => 'VideoKenTask',
    :application_version => '1.0.0'
  )
  youtube = client.discovered_api(YOUTUBE_API_SERVICE_NAME, YOUTUBE_API_VERSION)

  file_storage = Google::APIClient::FileStorage.new("client_secret_516051658702-o9o3fvmnl3gkq3l95aere6uhd4fjjsnh.apps.googleusercontent.com.json")
  if file_storage.authorization.nil?
    puts "hello";
    client_secrets = Google::APIClient::ClientSecrets.load
    flow = Google::APIClient::InstalledAppFlow.new(
      :client_id => client_secrets.client_id,
      :client_secret => client_secrets.client_secret,
      :scope => [YOUTUBE_UPLOAD_SCOPE]
    )
    client.authorization = flow.authorize(file_storage)
  else
    client.authorization = file_storage.authorization
  end
  #if client.authorization.refresh_token && client.authorization.expired?
  
  #end

  #client.authorization.access_token = '123'
  #client.authorization.token_credential_uri = 'http://localhost/oauth2callback'
  client.retries = 3

  return client, youtube
end

def main
  opts = Trollop::options do
    opt :file, 'Direct.mp4', :type => String
    opt :title, 'Video title', :default => 'Test Title', :type => String
    opt :description, 'Video description',
          :default => 'Test Description', :type => String
    opt :category_id, 'Numeric video category. See https://developers.google.com/youtube/v3/docs/videoCategories/list',
          :default => 22, :type => :int
    opt :keywords, 'Video keywords, comma-separated',
          :default => '', :type => String
    opt :privacy_status, 'Video privacy status: public, private, or unlisted',
          :default => 'public', :type => String
  end

  if opts[:file].nil? or not File.file?(opts[:file])
    Trollop::die :file, 'does not exist'
  end

  client, youtube = get_authenticated_service

  begin
    body = {
      :snippet => {
        :title => opts[:title],
        :description => opts[:description],
        :tags => opts[:keywords].split(','),
        :categoryId => opts[:category_id],
      },
      :status => {
        :privacyStatus => opts[:privacy_status]
      }
    }

    videos_insert_response = client.execute!(
      :api_method => youtube.videos.insert,
      :body_object => body,
      :media => Google::APIClient::UploadIO.new(opts[:file], 'video/*'),
      :parameters => {
        :uploadType => 'resumable',
        :part => body.keys.join(',')
      }
    )

    videos_insert_response.resumable_upload.send_all(client)

    puts "Video id '#{videos_insert_response.data.id}' was successfully uploaded."
  rescue Google::APIClient::TransmissionError => e
    puts e.result.body
  end
end

main
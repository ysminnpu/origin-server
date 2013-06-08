class Authentication < ActiveResource::Base
  include Console::GetupAdminHelper

  schema do
    string :id, :login, :password
  end

  def initialize
  end

  def generate(login, password)
    @login = login
    generate_token password
  end

  def expired?
    (Time.now.to_i - created_at > Console.config.authentication_session_expire.to_i)
  end

  def expires_in
    Console.config.authentication_session_expire.to_i - (Time.now.to_i - created_at)
  end

  def update_expires
    generate_token password
  end

  def generate_token(password)
    secret = Digest::SHA1.hexdigest(Console.config.authentication_session_key)
    token_text = "%02d" % password.length + password.reverse + Console.config.authentication_session_key + Time.now.to_i.to_s

    @token = ActiveSupport::MessageEncryptor.new(secret).encrypt_and_sign(token_text)
  end

  def password
    secret = Digest::SHA1.hexdigest(Console.config.authentication_session_key)
    token = ActiveSupport::MessageEncryptor.new(secret).decrypt_and_verify(@token)
    
    length = token[0..1].to_i + 1
    token[2..length].reverse
  end

  def change_password(password, new_password)

    response = getup_admin_post @login + "/account/password/change/", :oldpassword => password, :password1 => new_password, :password2 => new_password
    response_code = response.code.to_i

    generate_token new_password if response_code >= 200 and response_code < 400
    
    response
  end

  def reset_password(email)
    getup_admin_post "/account/password/reset/", :email => email
  end

  def update_password(password, token)
    response = getup_admin_post "/account/password/reset/key/" + token + "/", :password1 => password, :password2 => password
    response_code = response.code.to_i

    response_code >= 200 and response_code < 400
  end

  def login
    @login
  end

  private
    def created_at
      secret = Digest::SHA1.hexdigest(Console.config.authentication_session_key)
      token = ActiveSupport::MessageEncryptor.new(secret).decrypt_and_verify(@token)

      token[-10..-1].to_i
    end
end
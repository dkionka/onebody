class AccountController < ApplicationController
  filter_parameter_logging :password, :password_confirmation
  
  before_filter :check_ssl, :except => [:sign_out, :verify_code]

  def sign_in
    flash[:warning] = 'There are no users in the system.' unless Person.count > 0
    @salt = session_salt unless Setting.get(:features, :ssl)
    if request.post?
      if person = Person.authenticate(params[:email], Setting.get(:features, :ssl) ? params[:password] : params[:password_encrypted], :encrypted => !Setting.get(:features, :ssl), :salt => @salt)
        unless person.can_sign_in?
          redirect_to :controller => 'help', :action => 'unauthorized', :protocol => 'http://'
          return
        end
        session[:logged_in_id] = person.id
        session[:logged_in_name] = person.first_name + ' ' + person.last_name
        session[:ip_address] = request.remote_ip
        flash[:notice] = "Welcome, #{person.first_name}."
        if params[:from]
          redirect_to 'http://' + request.host + ([80, 443].include?(request.port) ? '' : ":#{request.port}") + params[:from]
        else
          redirect_to logged_in_url
        end
      elsif person == nil
        cookies[:email] = nil
        if family = Family.find_by_email(params[:email])
          flash[:warning] = 'That email address was found, but you must verify it before you can sign in.'
          redirect_to :action => 'verify_email', :email => params[:email]
        else
          flash[:warning] = 'That email address cannot be found in our system. Please try another email.'
        end
      else
        flash[:warning] = "The password you entered doesn't match our records. Please try again."
      end
    end
    @email = cookies[:email]
  end
  
  def sign_out
    session[:logged_in_id] = nil
    redirect_to logged_in_path
  end
  
  def edit
    @person = Person.find params[:id]
    raise 'Error.' unless @logged_in.can_edit? @person or @logged_in.admin?(:edit_profiles)
    if request.post?
      if params[:person][:email].to_s.any? and params[:person][:email] != @person.email
        @person.update_attributes :email => params[:person][:email], :email_changed => true
        if @person.errors.any?
          flash[:warning] = @person.errors.full_messages.join('; ')
        else
          flash[:notice] = 'Changes saved.'
          Notifier.deliver_email_update @person
        end
      end
      if @person.errors.empty? and (params[:person][:password].to_s.any? or params[:person][:password_confirmation].to_s.any?)
        @person.change_password params[:person][:password], params[:person][:password_confirmation]
        if @person.errors.any?
          flash[:warning] = @person.errors.full_messages.join('; ')
        else
          flash[:notice] = 'Changes saved.'
        end
      end
      if @person.errors.empty?
        redirect_to person_url(@person)
      end
    end
  end
  
  def verify_email
    if params[:email].to_s.any?
      person = Person.find_by_email(params[:email])
      family = Family.find_by_email(params[:email])
      if person or family
        if (person and person.can_sign_in?) or (family and family.people.any? and family.people.first.can_sign_in?)
          v = Verification.create :email => params[:email]
          if v.errors.any?
            render :text => v.errors.full_messages.join('; '), :layout => true
          else
            Notifier.deliver_email_verification(v)
            render :text => 'The verification email has been sent. Please check your email and follow the instructions in the message you receive. (You may have to wait a minute or two for the email to arrive.)', :layout => true
          end
        else
          redirect_to :controller => 'help', :action => 'bad_status', :protocol => 'http://'
        end
      else
        flash[:warning] = "That email address could not be found in our system. If you have another address, try again."
      end
    end
  end
  
  def verify_mobile
    if request.post? and params[:mobile].to_s.any? and params[:carrier].to_s.any?
      mobile = params[:mobile].scan(/\d/).join('').to_i
      person = Person.find_by_mobile_phone(mobile)
      if person
        if person.can_sign_in?
          unless gateway = MOBILE_GATEWAYS[params[:carrier]]
            raise 'Error.'
          end
          v = Verification.create :email => gateway % mobile, :mobile_phone => mobile
          if v.errors.any?
            render :text => v.errors.full_messages.join('; '), :layout => true
          else
            Notifier.deliver_mobile_verification(v)
            flash[:warning] = 'The verification message has been sent. Please check your phone and enter the code you receive.'
            redirect_to :action => 'verify_code', :id => v.id
          end
        else
          redirect_to :controller => 'help', :action => 'bad_status', :protocol => 'http://'
        end
      else
        flash[:warning] = "That mobile number could not be found in our system. You may try again."
      end
    end
  end
  
  def verify_birthday
    if request.post? 
      if params[:name].to_s.any? and params[:email].to_s.any? and params[:phone].to_s.any? and params[:birthday].to_s.any? and params[:notes].to_s.any?
        Notifier.deliver_birthday_verification(params)
        render :text => 'Your submission will be reviewed as soon as possible. You will receive an email once you have been approved.', :layout => true
      else
        flash[:warning] = 'You must complete all the required fields.'
      end
    end
  end
  
  def verify_code
    v = Verification.find params[:id]
    unless v.pending?
      render :text => 'There was an error.', :layout => true
      return
    end
    if params[:code].to_i > 0
      if v.code == params[:code].to_i
        if v.mobile_phone
          conditions = ['people.mobile_phone = ?', v.mobile_phone]
        else
          conditions = ['people.email = ? or families.email = ?', v.email, v.email]
        end
        @people = Person.find :all, :conditions => conditions, :include => :family
        if @people.nil? or @people.empty?
          render :text => "Sorry. There was an error. If you requested the church office make a change, it's possible it just hasn't been done yet. Please try again later.", :layout => true
          return
        elsif @people.length == 1
          person = @people.first
          session[:logged_in_id] = person.id
          flash[:warning] = "You must set your personal email address#{v.mobile_phone ? '' : ' (it may be different than the one you verified)'} and password to continue."
          redirect_to :action => 'edit', :id => person.id
        else
          session[:select_from_people] = @people
          redirect_to :action => 'select_person'
        end
        v.update_attribute :verified, true
      else
        v.update_attribute :verified, false
        render :text => 'You entered the wrong code.', :layout => true
      end
    end
  end
  
  def select_person
    unless session[:select_from_people]
      render :text => 'This page is no longer valid.', :layout => true
      return
    end
    @people = session[:select_from_people]
    if request.post? and params[:id] and @people.map { |p| p.id }.include?(params[:id].to_i)
      session[:logged_in_id] = params[:id].to_i
      session[:select_from_people] = nil
      flash[:warning] = 'You must set your personal email address and password to continue.'
      redirect_to :action => 'edit', :id => session[:logged_in_id]
    end
  end
  
  def safeguarding_children; redirect_to :controller => 'help', :action => 'safeguarding_children', :protocol => 'http://'; end

  private
    def check_ssl
      unless request.ssl? or RAILS_ENV != 'production' or !Setting.get(:features, :ssl)
        redirect_to :protocol => 'https://', :from => params[:from]
        return
      end
    end
    
    def session_salt
      unless session[:salt] and session[:salt_generated] > 5.minutes.ago
        session[:salt] = (0..25).inject('') { |r, i| r << rand(93) + 33 }
        session[:salt_generated] = Time.now
      end
      session[:salt]
    end
end

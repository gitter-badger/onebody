# == Schema Information
#
# Table name: families
#
#  id                   :integer       not null, primary key
#  name                 :string(255)
#  last_name            :string(255)
#  address1             :string(255)
#  address2             :string(255)
#  city                 :string(255)
#  state                :string(10)
#  zip                  :string(10)
#  home_phone           :string(25)
#  email                :string(255)
#  latitude             :float
#  longitude            :float
#  share_address        :boolean       default(TRUE)
#  share_mobile_phone   :boolean
#  share_work_phone     :boolean
#  share_fax            :boolean
#  share_email          :boolean
#  share_birthday       :boolean       default(TRUE)
#  share_anniversary    :boolean       default(TRUE)
#  legacy_id            :integer
#  updated_at           :datetime
#  wall_enabled         :boolean       default(TRUE)
#  visible              :boolean       default(TRUE)
#  share_activity       :boolean       default(TRUE)
#  site_id              :integer
#  share_home_phone     :boolean       default(TRUE)
#  deleted              :boolean
#  barcode_id           :string(50)
#  barcode_assigned_at  :datetime
#  barcode_id_changed   :boolean
#  alternate_barcode_id :string(50)
#

class Family < ActiveRecord::Base

  MAX_TO_BATCH_AT_A_TIME = 50

  has_many :people, :order => 'sequence', :dependent => :destroy
  accepts_nested_attributes_for :people
  belongs_to :site

  scope_by_site_id

  attr_accessible :name, :last_name, :address1, :address2, :city, :state, :zip, :home_phone, :email, :share_address, :share_mobile_phone, :share_work_phone, :share_fax, :share_email, :share_birthday, :share_anniversary, :wall_enabled, :visible, :share_activity, :share_home_phone
  attr_accessible :legacy_id, :barcode_id, :alternate_barcode_id, :people_attributes, :if => Proc.new { Person.logged_in and Person.logged_in.admin?(:edit_profiles) }

  has_one_photo :path => "#{DB_PHOTO_PATH}/families", :sizes => PHOTO_SIZES
  #acts_as_logger LogItem

  alias_method 'photo_without_logging=', 'photo='
  def photo=(p)
    LogItem.create :loggable_type => 'Recipe', :loggable_id => id, :object_changes => {'photo' => (p ? 'changed' : 'removed')}, :person => Person.logged_in
    self.photo_without_logging = p
  end

  sharable_attributes :mobile_phone, :address, :anniversary

  validates_uniqueness_of :barcode_id, :allow_nil => true, :scope => [:site_id, :deleted], :unless => Proc.new { |f| f.deleted? }
  validates_uniqueness_of :alternate_barcode_id, :allow_nil => true, :scope => [:site_id, :deleted], :unless => Proc.new { |f| f.deleted? }
  validates_length_of :barcode_id, :alternate_barcode_id, :in => 10..50, :allow_nil => true
  validates_format_of :barcode_id, :alternate_barcode_id, :with => /^\d+$/, :allow_nil => true

  validates_each [:barcode_id, :alternate_barcode_id] do |record, attribute, value|
    if attribute.to_s == 'barcode_id' and record.barcode_id
      if record.barcode_id == record.alternate_barcode_id
        record.errors.add(attribute, :taken)
      elsif Family.count('*', :conditions => ['alternate_barcode_id = ?', record.barcode_id]) > 0
        record.errors.add(attribute, :taken)
      end
    elsif attribute.to_s == 'alternate_barcode_id' and record.alternate_barcode_id
      if Family.count('*', :conditions => ['barcode_id = ?', record.alternate_barcode_id]) > 0
        record.errors.add(attribute, :taken)
      end
    end
  end

  def barcode_id=(b)
    write_attribute(:barcode_id, b.to_s.strip.any? ? b : nil)
    write_attribute(:barcode_assigned_at, Time.now.utc)
  end

  def alternate_barcode_id=(b)
    write_attribute(:alternate_barcode_id, b.to_s.strip.any? ? b : nil)
    write_attribute(:barcode_assigned_at, Time.now.utc)
  end

  def address
    address1.to_s + (address2.to_s.any? ? "\n#{address2}" : '')
  end

  def mapable?
    address1.to_s.any? and city.to_s.any? and state.to_s.any? and zip.to_s.any?
  end

  def mapable_address
    if mapable?
      "#{address1}, #{address2.to_s.any? ? address2+', ' : ''}#{city}, #{state} #{zip}".gsub(/'/, "\\'")
    end
  end

  # not HTML-escaped!
  def pretty_address
    a = ''
    a << address1.to_s   if address1.to_s.any?
    a << ", #{address2}" if address2.to_s.any?
    if city.to_s.any? and state.to_s.any?
      a << "\n#{city}, #{state}"
      a << "  #{zip}" if zip.to_s.any?
    end
  end

  def short_zip
    zip.to_s.split('-').first
  end

  def latitude
    return nil unless mapable?
    update_lat_lon unless read_attribute(:latitude) and read_attribute(:longitude)
    read_attribute :latitude
  end

  def longitude
    return nil unless mapable?
    update_lat_lon unless read_attribute(:latitude) and read_attribute(:longitude)
    read_attribute :longitude
  end

  def update_lat_lon
    return nil unless mapable? and Setting.get(:services, :yahoo).to_s.any?
    url = "http://api.local.yahoo.com/MapsService/V1/geocode?appid=#{Setting.get(:services, :yahoo)}&location=#{URI.escape(mapable_address)}"
    begin
      xml = URI(url).read
      result = REXML::Document.new(xml).elements['/ResultSet/Result']
      lat, lon = result.elements['Latitude'].text.to_f, result.elements['Longitude'].text.to_f
    rescue
      logger.error("Could not get latitude and longitude for address #{mapable_address} for family #{name}.")
    else
      update_attributes :latitude => lat, :longitude => lon
    end
  end

  self.digits_only_for_attributes = [:home_phone]

  def children_without_consent
    people.select { |p| !p.adult_or_consent? }
  end

  def visible_people
    people.find(:all).select do |person|
      !person.deleted? and (
        Person.logged_in.admin?(:view_hidden_profiles) or
        person.visible?(self)
      )
    end
  end

  def suggested_relationships
    all_people = people.all(:order => 'sequence')
    relations = {
      :adult => {
        :male => {
          :adult => {
            :female => 'wife'
          },
          :child => {
            :male   => 'son',
            :female => 'daughter'
          }
        },
        :female => {
          :adult => {
            :male => 'husband'
          },
          :child => {
            :male   => 'son',
            :female => 'daughter'
          }
        }
      },
      :child => {
        :male => {
          :adult => {
            :male   => 'father',
            :female => 'mother'
          }
        },
        :female => {
          :adult => {
            :male   => 'father',
            :female => 'mother'
          }
        }
      }
    }
    relationships = {}
    all_people.each_with_index do |person, person_index|
      relationships[person] ||= []
      person_adult = person_index <= 1 && person.adult?
      all_people.each_with_index do |related, related_index|
        related_adult = related_index <= 1 && related.adult?
        r = relations[person_adult ? :adult : :child][person.gender.to_s.downcase.to_sym][related_adult ? :adult : :child][related.gender.to_s.downcase.to_sym] rescue nil
        relationships[person] << [related, r] if r
      end
    end
    relationships
  end

  attr_accessor :dont_mark_barcode_id_changed

  before_update :mark_barcode_id_changed
  def mark_barcode_id_changed
    return if dont_mark_barcode_id_changed
    if changed.include?('barcode_id')
      self.write_attribute(:barcode_id_changed, true)
    end
  end

  before_save :set_synced_to_donortools
  def set_synced_to_donortools
   if (changed & %w(address city state zip home_phone)).any?
     self.people.all.each do |person|
       person.update_attribute(:synced_to_donortools, false)
     end
   end
   true
  end

  alias_method :destroy_for_real, :destroy
  def destroy
    people.all.each { |p| p.destroy }
    update_attribute(:deleted, true)
  end

  class << self

    # used to update a batch of records at one time, for UpdateAgent API
    def update_batch(records, options={})
      raise "Too many records to batch at once (#{records.length})" if records.length > MAX_TO_BATCH_AT_A_TIME
      records.map do |record|
        # find the family (by legacy_id, preferably)
        family = find_by_legacy_id(record['legacy_id'])
        if family.nil? and options['claim_families_by_barcode_if_no_legacy_id'] and record['barcode_id'].to_s.any?
          # if no family was found by legacy id, let's try by barcode id
          # but only if the matched family has no legacy id!
          # (because two separate families could potentially have accidentally been assigned the same barcode)
          family = find_by_legacy_id_and_barcode_id(nil, record['barcode_id'])
        end
        # last resort, create a new record
        family ||= new
        if options['delete_families_with_conflicting_barcodes_if_no_legacy_id'] and !family.new_record?
          # closely related to the other option, but this one deletes conflicting families
          # (only if they have no legacy id)
          destroy_all ["legacy_id is null and barcode_id = ? and id != ?", record['barcode_id'], family.id]
        end
        record.each do |key, value|
          value = nil if value == ''
          # avoid overwriting a newer barcode
          if key == 'barcode_id' and family.barcode_id_changed?
            if value == family.barcode_id # barcode now matches (presumably, the external db has been updated to match the OneBody db)
              family.write_attribute(:barcode_id_changed, false) # clear the flag
            else
              next # don't overwrite the newer barcode with an older one
            end
          elsif %w(barcode_id_changed remote_hash).include?(key) # skip these
            next
          end
          family.write_attribute(key, value) # be sure to call the actual method (don't use write_attribute)
        end
        family.dont_mark_barcode_id_changed = true # set flag to indicate we're the api
        if family.save
          s = {:status => 'saved', :legacy_id => family.legacy_id, :id => family.id, :name => family.name}
          if family.barcode_id_changed? # barcode_id_changed flag still set
            s[:status] = 'saved with error'
            s[:error] = "Newer barcode not overwritten: #{family.barcode_id.inspect}"
          end
          s
        else
          {:status => 'not saved', :legacy_id => record['legacy_id'], :id => family.id, :name => family.name, :error => family.errors.full_messages.join('; ')}
        end
      end
    end

    def new_with_default_sharing(attrs)
      attrs.symbolize_keys! if attrs.respond_to?(:symbolize_keys!)
      attrs.merge!(
        :share_address      => Setting.get(:privacy, :share_address_by_default),
        :share_home_phone   => Setting.get(:privacy, :share_home_phone_by_default),
        :share_mobile_phone => Setting.get(:privacy, :share_mobile_phone_by_default),
        :share_work_phone   => Setting.get(:privacy, :share_work_phone_by_default),
        :share_fax          => Setting.get(:privacy, :share_fax_by_default),
        :share_email        => Setting.get(:privacy, :share_email_by_default),
        :share_birthday     => Setting.get(:privacy, :share_birthday_by_default),
        :share_anniversary  => Setting.get(:privacy, :share_anniversary_by_default)
      )
      new(attrs)
    end

    def daily_barcode_assignment_counts(limit, offset, date_strftime='%Y-%m-%d', only_show_date_for=nil)
      [].tap do |data|
        counts = connection.select_all("select count(date(barcode_assigned_at)) as count, date(barcode_assigned_at) as date from families where site_id=#{Site.current.id} and barcode_assigned_at is not null group by date(barcode_assigned_at) order by barcode_assigned_at desc limit #{limit} offset #{offset};").group_by { |p| Date.parse(p['date']) }
        ((Date.today-offset-limit+1)..(Date.today-offset)).each do |date|
          d = date.strftime(date_strftime)
          d = ' ' if only_show_date_for and date.strftime(only_show_date_for[0]) != only_show_date_for[1]
          count = counts[date] ? counts[date][0]['count'].to_i : 0
          data << [d, count]
        end
      end
    end

  end
end

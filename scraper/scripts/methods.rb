require 'spreadsheet'
require 'rubyXL'
require 'csv'
require 'yaml'
require 'json'
require 'set'
require 'fileutils'
require 'nokogiri'
require 'open-uri'
require './methods_nach'
require './utils'

HEADINGS_INSERT = %w[
  BANK
  IFSC
  BRANCH
  ADDRESS
  CONTACT
  CITY
  DISTRICT
  STATE
].freeze

# These are not all the known states
# because the usage is quite limited for now
# TODO: Change this to a accurate mapping
# And store statecode instead
KNOWN_STATES = [
  'ANDHRA PRADESH',
  'DELHI',
  'GUJARAT',
  'JAMMU AND KASHMIR',
  'HIMACHAL PRADESH',
  'KARNATAKA',
  'KERALA',
  'MAHARASHTRA',
  'PUNJAB',
  'TAMIL NADU',
  'MADHYA PRADESH',
  'UTTARAKHAND',
  'RAJASTHAN',
  'TELANGANA',
  'WEST BENGAL'
].freeze

def parse_imps(banks)
  data = {}
  banknames = JSON.parse File.read('../../src/banknames.json')
  banks.each do |code, row|
    next unless row[:ifsc] && row[:ifsc].strip.to_s.length == 11

    data[row[:ifsc]] = {
      'BANK' => banknames[code],
      'IFSC' => row[:ifsc],
      'BRANCH' => "#{banknames[code]} IMPS",
      'CENTRE' => 'NA',
      'DISTRICT' => 'NA',
      'STATE' => 'NA',
      'ADDRESS' => 'NA',
      'CONTACT' => nil,
      'IMPS' => true,
      'CITY' => 'NA',
      'UPI' => banks[code][:upi] ? true : false
    }
  end
  data
end

def parse_neft(banks)
  data = {}
  codes = Set.new
  sheets = 0..1
  sheets.each do |sheet_id|
    row_index = 0
    headings = []
    log "Parsing #NEFT-#{sheet_id}.csv"
    headers = CSV.foreach("sheets/NEFT-#{sheet_id}.csv", encoding: 'utf-8', return_headers: false, headers: true, skip_blanks: true) do |row|
      row = row.to_h
      scan_contact = row['CONTACT'].to_s.gsub(/[\s-]/, '').scan(/^(\d+)\D?/).last
      row['CONTACT'] = parse_contact(row['STD CODE'], row['CONTACT'])

      row['MICR'] = row['MICR CODE']
      row.delete 'MICR CODE'
      row.delete 'STD CODE'

      row['ADDRESS'] = sanitize(row['ADDRESS'])
      row['BRANCH'] = sanitize(row['BRANCH'])
      row['STATE'] = sanitize(row['STATE'])
      row['DISTRICT'] = sanitize(row['DISTRICT'])
      row['CITY'] = sanitize(row['CITY'])

      row['IFSC'] = row['IFSC'].upcase.gsub(/[^0-9A-Za-z]/, '')
      codes.add row['IFSC']
      row['NEFT'] = true

      # This hopefully is merged-in from RTGS dataset
      row['CENTRE'] = nil
      bankcode = row['IFSC'][0..3]

      if banks[bankcode] and banks[bankcode].key? :upi and banks[bankcode][:upi]
        row['UPI'] = true
      else
        row['UPI'] = false
      end

      if data.key? row['IFSC']
        "Second Entry found for #{row['IFSC']}, discarding"
        next
      end
      data[row['IFSC']] = row
    end
  end
  data
end

# Parses the contact details on the RTGS Sheet
# TODO: Add support for parsing NEFT contact data as well
def parse_contact(std_code, phone)
  scan_contact = phone.to_s.gsub(/[\s-]/, '').scan(/^(\d+)\D?/).last
  scan_std_code = std_code.to_s.gsub(/[\s-]/, '').scan(/^(\d+)\D?/).last

  contact = scan_contact.nil? || (scan_contact == 0) || (scan_contact == '0') || (scan_contact.is_a?(Array) && (scan_contact == ['0'])) ? nil : scan_contact.first
  std_code = scan_std_code.nil? || (scan_std_code == 0) || (scan_std_code == '0') || (scan_std_code.is_a?(Array) && (scan_std_code == ['0'])) ? nil : scan_std_code.first

  # If std code starts with 0, strip that out
  if std_code and std_code[0] == '0'
    std_code = std_code[1..]
  end

  # If we have an STD code, use it correctly
  # Formatting as per E.164 format
  # https://en.wikipedia.org/wiki/E.164
  # if possible
  if std_code
    return "+91#{std_code}#{contact}"
  # If it looks like a mobile number
  elsif contact and contact.size > 9
    return "+91#{contact}"
  # This is a local number but we don't have a STD code
  # So we return the local number as-is
  elsif contact
    return contact
  else
    return nil
  end
end

def parse_rtgs(banks)
  data = {}
  sheets = 1..2
  sheets.each do |sheet_id|
    row_index = 0
    headings = []
    log "Parsing #RTGS-#{sheet_id}.csv"
    headers = CSV.foreach("sheets/RTGS-#{sheet_id}.csv", encoding: 'utf-8', return_headers: false, headers: true, skip_blanks: true) do |row|
      row = row.to_h
      micr_match = row['MICR_CODE'].to_s.strip.match('\d{9}')
      row['MICR'] = micr_match[0] if micr_match
      row['BANK'] = row.delete('BANK NAME')

      if row['STATE'].to_s.strip.match('\d')
        row = fix_row_alignment_for_rtgs(row)
      end

      row['CONTACT'] = parse_contact(row['STD CODE'], row['PHONE'])

      # There is a second header in the middle of the sheet.
      # :facepalm: RBI
      next if row['IFSC'].nil? or ['IFSC_CODE', 'BANK OF BARODA', '', 'KPK HYDERABAD'].include?(row['IFSC'])

      original_ifsc = row['IFSC']
      row['IFSC'] = row['IFSC'].upcase.gsub(/[^0-9A-Za-z]/, '').strip

      bankcode = row['IFSC'][0..3]

      if banks[bankcode] and banks[bankcode].key? :upi and banks[bankcode][:upi]
        row['UPI'] = true
      else
        row['UPI'] = false
      end

      if row['IFSC'].length != 11
        ifsc_11 = row['IFSC'][0..10]
        log "IFSC code longer than 11 characters: #{original_ifsc}, using #{ifsc_11}", :warn
        row['IFSC'] = ifsc_11
      end

      if data.key? row['IFSC']
        log "Second Entry found for #{row['IFSC']}, discarding", :warn
        next
      end
      row['ADDRESS'] = sanitize(row['ADDRESS'])
      row['BRANCH'] = sanitize(row['BRANCH'])
      row['RTGS'] = true
      # This isn't accurate sadly, because RBI has both the columns
      # all over the place. As an example, check LAVB0000882 vs LAVB0000883
      # which have the flipped values for CITY1 and CITY2
      row['CITY'] = sanitize(row['CITY2'])
      row['CENTRE'] = sanitize(row['CITY1'])
      row['DISTRICT'] = sanitize(row['CITY1'])
      # Delete rows we don't want in output
      # Merged into CONTACRT
      row.delete('STD CODE')
      row.delete('PHONE')
      row.delete('CITY1')
      row.delete('CITY2')
      data[row['IFSC']] = row
    end
  end
  data
end

def export_csv(data)
  CSV.open('data/IFSC.csv', 'wb') do |csv|
    keys = ['BANK','IFSC','BRANCH','CENTRE','DISTRICT','STATE','ADDRESS','CONTACT','IMPS','RTGS','CITY','NEFT','MICR','UPI', 'SWIFT']
    csv << keys
    data.each do |code, ifsc_data|
      sorted_data = []
      keys.each do |key|
        sorted_data << ifsc_data.fetch(key, "NA")
      end
      csv << sorted_data
    end
  end
end

def find_bank_codes(list)
  banks = Set.new

  list.each do |code|
    banks.add code[0...4] if code
  end
  banks
end

def find_bank_branches(bank, list)
  list.select do |code|
    if code
      bank == code[0...4]
    else
      false
    end
  end
end

def export_json_by_banks(list, ifsc_hash)
  banks = find_bank_codes list
  banks.each do |bank|
    hash = {}
    branches = find_bank_branches(bank, list)
    branches.sort.each do |code|
      hash[code] = ifsc_hash[code]
    end

    File.open("data/by-bank/#{bank}.json", 'w') { |f| f.write JSON.pretty_generate(hash) }
  end
end

def merge_dataset(neft, rtgs, imps)
  h = {}
  combined_set = Set.new(neft.keys) + Set.new(rtgs.keys) + Set.new(imps.keys)

  combined_set.each do |ifsc|

    data_from_neft = neft.fetch ifsc, {}
    data_from_rtgs = rtgs.fetch ifsc, {}
    data_from_imps = imps.fetch ifsc, {}

    # Preference Order is:
    # NEFT > RTGS > IMPS
    combined_data = data_from_imps.merge(
      data_from_rtgs.merge(data_from_neft) do |key, oldval, newval|
        if oldval and oldval != 'NA'
          oldval
        else
          newval
        end
      end
    ) do |key, oldval, newval|
        if oldval and oldval != 'NA'
          oldval
        else
          newval
        end
      end
    combined_data['NEFT'] ||= false
    combined_data['RTGS'] ||= false
    # IMPS is true everywhere, till we have clarity on this from NPCI
    combined_data['IMPS'] ||= true
    combined_data['UPI']  ||= false
    combined_data['MICR'] ||= nil
    combined_data['SWIFT'] = nil
    combined_data.delete('DATE')

    h[ifsc] = combined_data
  end
  h
end

def apply_bank_patches(dataset)
  Dir.glob('../../src/patches/banks/*.yml').each do |patch|
    data = YAML.safe_load(File.read(patch), [Symbol])
    banks = data['banks']
    patch = data['patch']
    banks.each do |bankcode|
      if dataset.key? bankcode
        dataset[bankcode].merge!(patch)
      else
        log "#{bankcode} not found in the list of ACH banks while applying patch", :info
      end
    end
  end
  dataset
end

def apply_patches(dataset)
  Dir.glob('../../src/patches/ifsc/*.yml').each do |patch|
    log "Applying #{patch}", :debug
    data = YAML.safe_load(File.read(patch))

    case data['action'].downcase
    when 'patch'
      codes = data['ifsc']
      patch = data['patch']
      codes.each do |code|
        log "Patching #{code}"
        dataset[code].merge!(patch) if dataset.has_key? code
      end
    when 'patch_multiple'
      codes = data['ifsc']
      codes.each_entry do |code, patch|
        log "Patching #{code}"
        dataset[code].merge!(patch) if dataset.has_key? code
      end
    when 'add_multiple'
      codes = data['ifsc']
      codes.each_entry do |code, data|
        log "Adding #{code}"
        dataset[code] = data
        dataset[code]['IFSC'] = code
      end
    when 'patch_bank'
      patch = data['patch']
      all_ifsc = dataset.keys
      banks = data['banks']
      banks.each do |bankcode|
        log "Patching #{bankcode}"
        codes = all_ifsc.select {|code| code[0..3] == bankcode}
        codes.each do |code|
          dataset[code].merge!(patch)
        end
      end

    when 'delete'
      codes = data['ifsc']
      codes.each do |code|
        dataset.delete code
        log "Removed #{code} from the list", :info
      end
    end
  end
  dataset
end

def export_json_list(list)
  File.open('data/IFSC-list.json', 'w') { |f| JSON.dump(list, f) }
end

def export_to_code_json(list)
  banks = find_bank_codes list
  banks_hash = {}

  banks.each do |bank|
    banks_hash[bank] = find_bank_branches(bank, list).map do |code|
      # this is to drop lots of zeroes
      branch_code = code.strip[-6, 6]
      if branch_code =~ /^(\d)+$/
        branch_code.to_i
      else
        branch_code
      end
    end
  end

  File.open('data/IFSC.json', 'w') do |file|
    file.puts banks_hash.to_json
  end
end

def log(msg, status = :info)
  case status
  when :info
    msg = "[INFO] #{msg}"
  when :warn
    msg = "[WARN] #{msg}"
  when :critical
    msg = "[CRIT] #{msg}"
  when :debug
    msg = "[DEBG] #{msg}"
  end
  puts msg
end

# Downloads the SWIFT data from
# https://sbi.co.in/web/nri/quick-links/swift-codes
def validate_sbi_swift
  doc = Nokogiri::HTML(URI.open("https://sbi.co.in/web/nri/quick-links/swift-codes"))
  table = doc.css('tbody')[0]
  website_bics = Set.new

  for row in table.css('tr')
    website_bics.add row.css('td')[2].text.gsub(/[[:space:]]/, '')
  end

  # Validate that all of these are covered in our swift patch
  patch_bics = YAML.safe_load(File.read('../../src/patches/ifsc/sbi-swift.yml'))['ifsc']
    .values
    .map {|x| x['SWIFT']}
    .to_set

  missing = (website_bics - patch_bics)
  if missing.size != 0
    log "[SBI] Missing SWIFT/BICs for SBI. Please match https://sbi.co.in/web/nri/quick-links/swift-codes to src/patches/ifsc/sbi-swift.yml", :critical
    log "[SBI] You can use https://www.sbi.co.in/web/home/locator/branch to find IFSC from BRANCH code or guess it as SBIN00+BRANCH_CODE", :info
    log "[SBI] Count of Missing BICS: #{missing.size}", :debug
    log "[SBI] Missing BICS follow", :debug
    log missing.to_a.join(", "), :debug
    exit 1
  end
end

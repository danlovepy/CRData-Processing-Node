#!/usr/bin/env ruby
#
require 'rubygems'
require 'hpricot'
require 'logger'
require 'ftools'
require 'right_aws'
require 'fileutils'
require 'rake'
require 'rsruby'
require 'cgi'

require 'global'


class Job
  JOB_FIELDS = %w[name value kind data_set_s3_file]
  PARAM_NAME = "name"
  PARAM_VALUE = "value"
  PARAM_KIND = "kind"
  PARAM_DATA_SET = "data_set_s3_file"
  VALUE_DATA_SET = "Dataset"
  VALUE_INTEGER = "Integer"
  VALUE_BOOLEAN = "Boolean"
  VALUE_ENUMERATION = "Enumeration"
  VALUE_STRING = "String"

  attr_reader :r_script_filename, :job_id, :curr_uuid, :r_call_interface

  def initialize(xml_response)
    @r_call_interface = RSRuby.instance
    @r_script_filename = nil
    @job_id = 0
    @curr_uuid = Global.rand_uuid
    # log request
    Global.logger.info(xml_response)
    
    # go back to root dir before starting
    FileUtils.cd Global.root_dir
    
    Global.create_if_missing_directory @curr_uuid
    @r_script_filename = "#{@curr_uuid}/#{@curr_uuid}.r"
    doc = Hpricot::XML(xml_response)

    # at the moment we extract only JOB ID and script content
    # rest such as data we will look at it in later phases.
    @job_id = (doc/'job'/'id').inner_text
    Global.logger.info("JOB_ID = #{@job_id}, LOCAL_DIR = #{Global.root_dir}/#{@curr_uuid}, SCRIPT_NAME = #{@r_script_filename}")
    r_script = (doc/'source-code').inner_text
    r_script_file_handle = File.open(@r_script_filename, aModeString="w")
    r_script_file_handle.puts r_script
    r_script_file_handle.close

    # just some temporary logic/hack for data if script uses some .dat,.csv file
    # this will be removed when we have data support in CRdata
    #`cp /tmp/*.dat /tmp/*.csv #{Dir::pwd}/#{@curr_uuid}`
    (doc/:param).each do |param|
      job_params = {}

      JOB_FIELDS.each do |el|
        job_params[el] = CGI::unescapeHTML(param.at(el).innerHTML)
      end

      if job_params[PARAM_KIND] == VALUE_DATA_SET
        just_name = job_params[PARAM_DATA_SET].to_s.last_part
        @r_call_interface.assign(job_params[PARAM_NAME], just_name)
        Global.logger.info("R_PARAMETER::#{job_params[PARAM_NAME]} = #{just_name}")

        data_file_handle = File.new("#{Global.root_dir}/#{@curr_uuid}/#{just_name}", 'wb')
        # stream file in chunks especially makes more sense for larger files
        rhdr = Global.s3if.get(Global::MAIN_BUCKET, job_params[PARAM_DATA_SET].to_s.clean_s3_url) do |chunk|
          data_file_handle.write chunk
        end
        data_file_handle.close
      elsif job_params[PARAM_KIND] == VALUE_STRING
        @r_call_interface.assign(job_params[PARAM_NAME], job_params[PARAM_VALUE].to_s)
        Global.logger.info("R_PARAMETER::#{job_params[PARAM_NAME]} = #{job_params[PARAM_VALUE]}")
      else
        @r_call_interface.assign(job_params[PARAM_NAME], job_params[PARAM_VALUE].to_f)
        Global.logger.info("R_PARAMETER::#{job_params[PARAM_NAME]} = #{job_params[PARAM_VALUE]}")
      end
    end
  end

  def run
    Global.logger.info('successfully created job and saved R file')
    # this will run the R program that generates log file and results
    #system "cd #{Dir::pwd}/#{@curr_uuid}; r CMD BATCH #{@curr_uuid}.r; mv #{@curr_uuid}.r.Rout job.log; "
    @r_call_interface.setwd("#{Global.root_dir}/#{@curr_uuid}")
    @r_call_interface.eval_R("source('#{@curr_uuid}.r')")
  end

  def get_id
    @job_id.to_s
  end

  def normalized_get_id
    # first create a specific object name for S3
    # current convention is that JOB ID is maximum 10 digits
    # so if job_id < 10 digits, then prepend 0s
    local_str_job_id = get_id
    len_str_job_id = local_str_job_id.length
    while len_str_job_id <= 9
      local_str_job_id = "0" + local_str_job_id
      len_str_job_id += 1
    end

    local_str_job_id
  end

  def store_results_and_logs
    # first store log
    begin
      puts "LOG_FILE = logs/job_#{normalized_get_id}/job.log"
      Global.s3if.put(Global::MAIN_BUCKET, "logs/job_#{normalized_get_id}/job.log", File.open("#{Global.root_dir}/#{@curr_uuid}/job.log"), Global::S3_OPTIONS)
    rescue => err_store_log
      Global.logger.info('probably no error log generated, happens for successful jobs that have no output or error')
    end
    # now iterate through directory and store all results files (web content only)
    
    # upload only web content files for results
    # .html,.htm,.css,.png,.pdf,.jpg
    # iterate through directory and store files one at a time in S3
    upload_files = Dir[File.join("#{Global.root_dir}/#{@curr_uuid}", "*")].select{|file| File.ftype(file) == "file" &&
                  (File.extname(file) == '.jpg' ||
                  File.extname(file) == '.png' ||
                  File.extname(file) == '.html' ||
                  File.extname(file) == '.htm' ||
                  File.extname(file) == '.js' ||
                  File.extname(file) == '.css' ||
                  File.extname(file) == '.pdf')}.each{|name|
                      name = name.split("/").last
                      puts "RESULTS_FILE = #{Global.root_dir}/#{@curr_uuid}/#{name}"
                      Global.s3if.put(Global::MAIN_BUCKET, "results/job_#{normalized_get_id}/#{name}", File.open("#{Global.root_dir}/#{@curr_uuid}/#{name}"), Global::S3_OPTIONS)
                  }

  end
end

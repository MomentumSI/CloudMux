#
# (c) Copyright 2012-2013 Transcend Computing, Inc.
#
# Licensed under the Apache License, Version 2.0 (the License);
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an AS IS BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'cloudmux/jenkins/client'

module CloudMux
  module Chef
    class ContinuousIntegration < CloudMux::Jenkins::Client

      attr_accessor :chef_repo

      DEPLOY_CONFIG = "#{File.dirname(__FILE__)}/configs/deploy_config.yml"

      def create_build_job(cookbook_name)
        path = cookbook_path(cookbook_name)
        job_name = get_job_name(cookbook_name, 'build')
        job_config = base_job_config.merge(
          path: path, scm_url: @chef_repo.url, name: cookbook_name
          )
        template = job_template(File.join('chef', 'build'), job_config)
        save_job(job_name, template)
      end

      def create_deploy_job(cookbook_name, driver, platform)
        job_config = base_job_config
        job_name = get_job_name(cookbook_name, "#{driver}_#{platform}")
        job_config[:path] = cookbook_path(cookbook_name)
        job_config[:app_endpoint] = '${JENKINS_URL}'
        template = job_template(File.join('chef', 'kitchen'), job_config)
        save_job(job_name, template)
      end

      def generate_all_build_jobs
        @chef_repo.cookbook_names.each do |name|
          create_build_job(name)
        end
      end

      def generate_all_deploy_jobs
        deployers_config['driver_plugins'].each do |driver, platforms|
          platforms.each do |platform, config|
            @chef_repo.cookbook_names.each do |cb_name|
              create_deploy_job(cb_name, driver, platform)
            end
          end
        end
      end

      # job_name needs to be of format:
      #   'cookbook__branch__driver_platform__chef'
      def generate_deploy_suites(job_name, deploy_config = nil)
        info                = job_name.split('__')
        cookbook_name, test = info[0], info[2].split('_')
        driver, platform    = test[0], test[1]
        if deploy_config.nil?
          kitchen_obj = generate_default_deploy_obj(cookbook_name)
        else
          kitchen_obj = YAML.load(deploy_config)
        end
        driver_cfg = deployers_config['driver_plugins'][driver][platform]
        kitchen_obj['suites'].each do |suite|
          suite['driver'] = { 'name' => driver }
          suite['platforms'] = [{ 'name' => platform, 'driver_config' => driver_cfg }]
        end
        kitchen_obj.to_yaml
      end

      def build_job_status(cookbook, job_type)
        job_name = get_job_name(cookbook, 'build')
        results = get_status(job_name, job_type)
        { "#{job_type}_status" => results }
      end

      def all_build_job_states(cookbook)
        states = {}
        %w{ rspec foodcritic syntax }.each do |type|
          states.merge!(build_job_status(cookbook, type))
        end
        states
      end

      def deploy_job_status(cookbook, driver, platform)
        deploy_job = get_job_name(cookbook, "#{driver}_#{platform}")
        status = get_status(deploy_job, "#{driver}_#{platform}")
        { "#{driver}_#{platform}_status" => status }
      end

      def all_deploy_job_states(cookbook)
        states = {}
        deployers_config['driver_plugins'].each do |driver, platforms|
          platforms.each do |platform, config|
            states.merge! deploy_job_status(cookbook, driver, platform)
          end
        end
        states
      end

      def get_all_states
        status = {}
        @chef_repo.cookbook_names.each do |cb_name|
          status[cb_name] = {}
          status[cb_name].merge! all_build_job_states(cb_name)
          status[cb_name].merge! all_deploy_job_states(cb_name)
        end
        status
      end

      def generate_all_jobs
        generate_all_build_jobs
        generate_all_deploy_jobs
      end

      private

      def get_job_name(cookbook, job_type)
        [cookbook, @chef_repo.branch, job_type, 'chef'].join('__')
      end

      def cookbook_path(name)
        @chef_repo.find_relative_cookbook_path(name)
      end

      def deployers_config
        @deploy_config ||= YAML.load_file DEPLOY_CONFIG
      end

      def base_job_config
        { scm_url: @chef_repo.url, branch: @chef_repo.branch }
      end

    end
  end
end

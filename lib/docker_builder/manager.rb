module DockerBuilder
class Manager

  def self.save_chef_config(settings)
    require 'json'
    filename = settings.filename_chef_config
    FileUtils.mkdir_p(File.dirname(filename))
    File.open(filename,"w+") do |f|
      f.write(settings.all_attributes.to_json)
    end

    true
  end


  def self.save_config_json(settings)
    require 'json'
    filename = settings.filename_config_json
    FileUtils.mkdir_p(File.dirname(filename))
    File.open(filename,"w+") do |f|
      f.write(settings.all_attributes.to_json)
    end

    true
  end

  ###
  def self.build_image(server_name, settings=nil)
    puts "building image for #{server_name}..."
    #puts "settings: #{settings}"
    #puts "debug: #{settings['properties']}"

    #settings = load_settings(server_name)

    t = settings['build']['build_type']
    if t=='' || t=='none'
      #
      puts "no build needed..."

    elsif t.downcase=='dockerfile'
      return build_image_with_dockerfile(settings)
    elsif t=='chef'
      return build_image_with_chef(settings)
    elsif t=='packer'
      return build_image_with_packer(settings)
    end
  end

  def self.build_image_with_dockerfile(settings)
    puts "build image with Dockerfile"

    #cmd %Q(cd #{name} && docker build -t #{settings.image_name} . )
    cmd %Q(docker build -t #{settings.image_name} #{settings.dir_server_root} )

  end

  def self.build_image_with_chef(settings)
    puts "build image with chef"

    # config json
    save_chef_config(settings)

    # check node
    cmd %Q(cd #{Config.root_path} && chef exec knife node show #{settings.chef_node_name} -c #{chef_config_knife_path})


    #cmd %Q(SERVER_NAME=#{settings.name} SERVER_PATH=#{settings.dir_server_root} chef exec chef-client -z -N #{settings.image_name} -j #{settings.filename_config_json} -c #{chef_config_knife_path} #{chef_recipe_path('chef_build_image.rb')} )
    res_recipe = run_chef_recipe(settings, 'chef_build_image.rb')
  end


  def self.build_image_with_packer(settings)
    require_relative '../../lib/docker_builder/builder/packer'

    puts "build image with packer"

    builder = DockerBuilder::Builder::Packer.new(settings)
    builder.build
  end



  ### run

  def self.run_container(server_name, settings={})
    puts "creating and running container.."
    #settings = load_settings(server_name)

    # destroy
    destroy_container(server_name, settings)


    # provision host before running container
    res_install = _install_container_provision_host(settings)

    # run container
    res_run = _run_container(settings)


    # TODO: systemd service
    #res_service = _install_service_container(settings)


  end

  def self._install_container_provision_host(settings)
    script_type = (settings['install']['host']['script_type'] rescue nil)
    return true unless script_type

    # run provision script on the host machine
    if script_type=='chef_recipe'
      return _install_container_provision_host_chef_recipe(settings)
    else
      # do nothing
    end

    true
  end


  #
  def self._install_container_provision_host_chef_recipe(settings)
    # run script on host machine
    script_name = settings['install']['host']['script'] || 'install_host'

    # check script exists
    #script_path = "#{settings.name}/cookbooks/#{settings.name}/recipes/#{script_name}.rb"
    #f = File.expand_path('.', script_path)

    #if !File.exists?(f)
    #  puts "script not found: #{f}. Skipping"
    #  return false
    #end

    #puts "pwd= #{Dir.pwd}"
    #puts "root = #{Config.root_path}"
    #exit

    #
    res_chef = run_chef_recipe_server_recipe(settings, script_name)
    #cmd %Q(SERVER_NAME=#{settings.name} chef-client -z -N #{settings.name} --override-runlist 'recipe[#{settings.name}::#{script_name}]' )

    return true
  end

  # run
  def self._run_container(settings)
    puts "run container ..."

    # generate config
    save_config_json(settings)

    # create
    create_container(settings)

    setup_network(settings)


    ### START && run provision after start
    start_container(name, settings)

    true
  end

  def self.create_container(settings)
    #puts "networks: #{settings['docker']['network']}"
    # create
    net_options = ""
    networks = settings['docker'].fetch('network', {}).fetch('networks', [])
    if networks && networks[0]
      network = networks[0]
      #puts "network=#{network}"
      net_options << "--net #{network['net']} "
      net_options << "--ip #{network['ip']} "  if network['ip']
      net_options << "--mac-address #{network['mac_address']} "  if network['mac_address']
    end


    cmd %Q(docker create --name #{settings.container_name} #{net_options} #{settings.docker_ports_string} #{settings.docker_volumes_string} #{settings.docker_volumes_from_string} #{settings.docker_links_string}  #{settings.run_extra_options_string} #{settings.run_env_variables_string} #{settings.image_name} #{settings['docker']['command']} #{settings['docker']['run_options']})
  end


  def self.setup_network(settings)
    container_name = settings.container_name

    # networks
    networks = settings['docker'].fetch('network', {}).fetch('networks', [])
    if networks
      ind = 0
      networks.each do |net|
        ind = ind + 1

        #
        next if net['action']=='remove'

        # skip first network
        next if ind==1



        # connect
        ip = net['ip']
        s_ip = "--ip #{ip}" if ip
        #puts %Q(docker network connect #{s_ip}  #{net['net']} #{settings.container_name})
        cmd %Q(docker network connect #{s_ip}  #{net['net']} #{settings.container_name})
      end

      # remove
      networks.each do |net|
        next unless net['action']=='remove'
        cmd %Q(docker network disconnect #{net['net']} #{settings.container_name})
      end
    end
  end



  def self.start_container(name, settings)
    ### BEFORE START

    # run setup provision scripts
    setup_scripts = (settings['provision']['setup'] rescue [])
    if setup_scripts
      setup_scripts.each do |script|
        _run_setup_script(settings, script)
      end
    end


    # prepare before start
    prepare_before_start(settings)



    # start
    cmd %Q(docker start #{settings.container_name})

    # wait
    wait_until_running(settings.container_name)

    # setup
    setup_container_after_start(settings)

    # provision after start
    run_provision_after_start(settings)
  end


  def self.wait_until_running(container_name)
    retries = 10
    until system("docker exec #{container_name} true") || retries < 0
      sleep 1
      retries = retries - 1
    end

    assert_container_running(container_name)
  end

  def self.assert_container_running(container_name)
    res = system("docker exec #{container_name} true")
    assert res, "Container #{container_name} is not running"
  end

  def self.prepare_before_start(settings)
    puts "prepare_before_start"

    # prepare for chef scripts
    bootstrap_scripts = (settings['provision']['bootstrap'] rescue [])

    # before start
    if bootstrap_scripts
      bootstrap_scripts.each do |script|
        if script['type']=='chef'
          _prepare_provision_before_start_chef(settings, script)
        end
      end
    end

  end

  def self._prepare_provision_before_start_chef(settings, script)
    puts "_prepare_provision_before_start_chef"

    require_relative '../../lib/docker_builder/provisioner/provisioner_chef'

    provisioner = DockerBuilder::Provisioner::ProvisionerChef.new(settings)
    provisioner.copy_config_file

  end


  def self.setup_container_after_start(settings)

    # default gateway
    network = settings['docker']['network']
    if network
      gateway = network['default_gateway']

      if gateway
        # fix default gateway
        #cmd %Q(docker exec #{settings.container_name} ip route change default via #{gateway} dev eth1)
        cmd %Q(docker exec #{settings.container_name} ip route change default via #{gateway})
      end
    end



    # fix hosts
    container_hosts = settings['docker']['hosts'] || []
    container_hosts.each do |r|
      #cmd %Q(docker exec #{settings.container_name} bash -c 'echo "#{r[0]} #{r[1]}" >>  /etc/hosts')
      cmd %Q(docker exec #{settings.container_name} sh -c 'echo "#{r[0]} #{r[1]}" >>  /etc/hosts')
    end
  end



  def self.run_provision_after_start(settings)
    puts "run_provision_after_start"

    # run bootstrap provision scripts
    bootstrap_scripts = (settings['provision']['bootstrap'] rescue [])
    if bootstrap_scripts
      bootstrap_scripts.each do |script|
        _run_bootstrap_script(settings, script)
      end
    end


=begin
# commented - 2017-02-22

    #
    install_node_script_type = (settings['install']['node']['script_type'] rescue nil)
    install_bootstrap_script = (settings['install']['bootstrap']['script'] rescue nil)

    if install_node_script_type && install_node_script_type=='chef_recipe'
      # run container and provision with chef
      #_run_container_chef(settings)

      # ???
      #_provision_container_chef_recipe(settings)

    elsif install_node_script_type && install_node_script_type=='shell'
      # docker run
      #create_and_run_container(settings)

      # provision with shell script
      run_shell_script_in_container(settings, "install.sh")

    else
      # no script for provision
      #_run_container_docker(settings)

      # docker run
      #create_and_run_container(settings)

    end

    # bootstrap
    if install_bootstrap_script
      #script = settings['install']['bootstrap']['script'] || '/opt/bootstrap/bootstrap.sh'

      # bootstsrap with shell script
      run_bootstrap_shell_script_in_container(settings, install_bootstrap_script)
    end
=end



    true
  end

  def self._run_bootstrap_script(settings, script)
    puts "run BS script #{script}"

    if script['type']=='shell' && script['run_from']=='host'
      return _run_bootstrap_script_shell_from_host(settings, script)
    elsif script['type']=='shell' && (script['run_from'].nil? || script['run_from']=='')
      _run_bootstrap_script_shell_in_container(settings, script)
    end

    return nil
  end


  def self._run_bootstrap_script_shell_from_host(settings, script)
    cmd %Q(cd #{settings.dir_server_root} && #{script['script']} )

  end


  def self._run_bootstrap_script_shell_in_container(settings, script)
    script_path = script['script']
    # exec
    cmd %Q(docker exec #{settings.container_name} #{script_path} )
  end




  ### systemd service

  def self._install_service_container(settings)
    # not work
    #cmd %Q(SERVER_NAME=#{settings.name} chef-client -z -N #{settings.name} install_container_service.rb )

    # work
    #cmd %Q(SERVER_NAME=#{settings.name} chef-client -z -N #{settings.name} -j config_run_install_container_service.json )

    # work
    #cmd %Q(SERVER_NAME=#{settings.name} chef-client -z -N #{settings.name} --override-runlist 'recipe[server-api::install_container_service]' )

    #
    cmd %Q(SERVER_NAME=#{settings.name} chef-client -z -N #{settings.name} -j config/config-#{settings.name}.json --override-runlist 'recipe[server-api::install_container_service]' )
  end


  def self._remove_service_container(settings)
    cmd %Q(SERVER_NAME=#{settings.name} chef-client -z -N #{settings.name} -j config/config-#{settings.name}.json --override-runlist 'recipe[server-api::remove_container_service]' )
  end


  ### provision

  def self._run_setup_script(settings, script)
    if script['type']=='shell'
      return _run_setup_script_shell_from_host(settings, script)
    end

    return nil
  end

  def self._run_setup_script_shell_from_host(settings, script)
    cmd %Q(cd #{settings.dir_server_root} && #{script['script']} )
  end




  def self._provision_container_chef_recipe(settings)
    puts "provisioning container #{settings.container_name}"

    #cmd %Q(SERVER_NAME=#{settings.name} chef-client -z -N #{settings.name} #{settings.name}/cookbooks/#{settings.name}/ )
  end

=begin

  def self._run_container_docker(settings)

  end
=end

  def self._run_container_chef(settings)
    # generate json config for chef
    save_chef_config(settings)

    # run chef
    #s_run = %Q(cd #{settings.name} && chef-client -z -j config.json -c ../.chef/knife.rb -N #{settings.name} ../lib/chef_container_run.rb)

    # good - 2016-nov-19
    #cmd %Q(SERVER_NAME=#{settings.name} chef-client -z -N #{settings.name} chef_run_container.rb)

    #
    res_chef = run_chef_recipe(settings, 'chef_run_container.rb')

    res_chef
  end


  def self.destroy_image(server_name, settings={})
    puts "destroying image for server #{server_name}"

    cmd %Q(docker rmi #{settings.image_name} )
    cmd %Q(docker rm -f chef.converge.#{settings.image_name} )

    # delete chef data
    if settings['build']['build_type']=='chef'
      return destroy_image_chef(settings)
    end
  end


  def self.destroy_image_chef(settings)
    puts "destroying image with chef..."

    # config json
    save_chef_config(settings)

    # destroy temp container
    cmd %Q(docker rm -f chef-converge.#{settings.image_name} )

    #
    cmd %Q(cd #{Config.root_path} && chef exec knife node delete #{settings.chef_node_name}  -y -c #{chef_config_knife_path})

    res_recipe = run_chef_recipe(settings, 'chef_destroy_image.rb')

    chef_remove_data(settings)

    # work - before 2016-nov-19
    #cmd %Q(cd #{Config.root_path} && chef exec knife node delete #{settings.chef_node_name}  -y -c #{chef_config_knife_path})

    # clean chef client, node
    #cmd %Q(cd #{Config.root_path} && rm -f #{settings.filename_chef_node_json} )
    #cmd %Q(cd #{Config.root_path} && rm -f #{settings.filename_chef_client_json} )
  end

  ###


  def self.destroy_container(server_name, settings)
   puts "destroying container #{server_name}..."

   # TODO: stop, remove systemd service
   #res_service = _remove_service_container(settings)

   #
   cmd %Q(docker rm -f #{settings.container_name} )



   # if chef
   if settings['build']['build_type']=='chef'
     return destroy_container_chef(settings)
   end

   #
   return true
 end


  def self.destroy_container_chef(settings)
    # destroy temp container
    cmd %Q(docker rm -f chef-converge.#{settings.image_name} )

    #
    res_chef = run_chef_recipe(settings, 'chef_destroy_container.rb')
    #cmd %Q(SERVER_NAME=#{settings.name} chef-client -z -N #{settings.name} chef_destroy_container.rb)

    #
    chef_remove_data(settings)

  end




  ### stop container

  def self.stop_container(server_name, settings)
    puts "stopping container #{server_name}..."

    #
    cmd %Q(docker stop #{settings.container_name} )

    #
    return true
  end


  ### run task on running container
  def self.exec_task(server_name, recipe_name)
    #raise 'not implemented'

    settings = load_settings(server_name)

    # check script exists
    script_path = "#{settings.name}/cookbooks/#{settings.name}/recipes/#{recipe_name}.rb"
    f = File.expand_path('.', script_path)

    if !File.exists?(f)
      puts "script not found: #{f}. Skipping"
      return false
    end

    #
    cmd %Q(SERVER_NAME=#{settings.name} chef-client -z --override-runlist 'recipe[server-api::exec_container]' )
    #cmd %Q(SERVER_NAME=#{settings.name} chef-client -z -N #{settings.name} --override-runlist 'recipe[#{settings.name}::#{recipe_name}]' )
    #cmd %Q(SERVER_NAME=#{settings.name} chef-client -z -N #{settings.name} chef_exec_container.rb )

    return true
  end

  ###
  def self.clear_cache(name, settings)
    # common cache
    cmd("rm -rf ~/.chef/cache")
    cmd("rm -rf ~/.chef/local-mode-cache")

    # cache for server
    cmd("rm -rf #{settings.dir_server_root}/.chef/local-mode-cache")
    #cmd("rm -rf ~/.chef/package-cache")

    # cache in gem
    cmd("rm -rf #{Config.dir_gem_root}/lib/docker_builder/.chef/local-mode-cache")


  end

  ###

  def self.cmd(s)
    Command.cmd(s)
  end


  ### helpers - shell

  def self.run_shell_script_in_container(settings, script_name)
    script_path = settings.make_path_full("scripts/#{script_name}")

    # copy
    cmd %Q(cd #{Config.root_path} && docker cp #{script_path} #{settings.container_name}:/tmp/#{script_name} )

    # exec
    cmd %Q(docker exec #{settings.container_name} chmod +x /tmp/#{script_name} )
    cmd %Q(docker exec #{settings.container_name} /tmp/#{script_name} )
  end


  ### helpers - chef

  def self.run_chef_recipe(settings, recipe_rb)
    cmd %Q(cd #{Config.root_path} && SERVER_NAME=#{settings.name} SERVER_PATH=#{settings.dir_server_root} chef exec chef-client -z -N #{settings.container_name} -j #{settings.filename_config_json} -c #{chef_config_knife_path} #{chef_recipe_path(recipe_rb)} )
  end

  def self.run_chef_recipe_server_recipe(settings, server_recipe)
    cmd %Q(cd #{Config.root_path} && SERVER_NAME=#{settings.name} SERVER_PATH=#{settings.dir_server_root} chef exec chef-client -z -N #{settings.container_name} -c #{chef_config_knife_path} --override-runlist 'recipe[#{settings.name}::#{server_recipe}]' )
  end


  def self.chef_config_knife_path
    "#{Config.dir_gem_root}/lib/docker_builder/chef/.chef/knife.rb"
  end

  def self.chef_recipe_path(p)
    "#{Config.dir_gem_root}/lib/docker_builder/chef/#{p}"
  end


  def self.chef_remove_data(settings)
    #
    cmd %Q(cd #{Config.root_path} && chef exec knife node delete #{settings.chef_node_name}  -y -c #{chef_config_knife_path})

    # clean chef client, node
    cmd %Q(cd #{Config.root_path} && rm -f #{settings.filename_chef_node_json} )
    cmd %Q(cd #{Config.root_path} && rm -f #{settings.filename_chef_client_json} )
  end


  ### common helpers
  def self.assert(expression, string = "Assert failed")
    unless expression
      throw Exception.new string
    end
  end

end
end

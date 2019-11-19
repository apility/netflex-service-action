
require "aws-sdk-ecs"
require "optparse"

options = {}

OptionParser.new do |opts|
  opts.banner = "Usage: action.rb [options]"

  opts.on("-pNAME", "--pull-request=NAME", "Pull request number (usually in 'PR-#' format)") do |name|
    options[:PR_TAG] = name
  end

  opts.on("-rNAME", "--revision=NAME", "Revision number for ") do |name|
    options[:BASE_TAG] = name
  end

  opts.on("-RNAME", "--repository=NAME", "ECR Repository (for example: netflexsites/grieghallen or apility/netflexapp)") do |name|
    options[:REPOSITORY] = name
  end

  opts.on("-cNAME" "--cluster=NAME", "Optional cluster name") do |name|
    options[:CLUSTER] = name
  end

  opts.on("-m", "--pr", "Create (or update) service") do
    options[:CREATE] = true
  end

  opts.on("-t", "--teardown", "Tear down service") do
    options[:TEARDOWN] = true
  end
end.parse!

unless options.fetch(:CREATE, false) or options.fetch(:TEARDOWN, false) 
  puts "Need either -m or -t"
  exit
end

PR_TAG = "pr-" + /refs\/pull\/(\d+)\/merge/.match(options.fetch(:PR_TAG))[1] || netflexsites
unless PR_TAG
  puts "Unable to extract pull request number"
  exit
end
REPOSITORY = options.fetch(:REPOSITORY).downcase
SITE_NAME = /\/(.*)$/.match(REPOSITORY)[1]
CLUSTER = options.fetch(:CLUSTER, "Netflex")

class Hash
  def except(*keys)
    dup.except!(*keys)
  end

  def except!(*keys)
    keys.each { |key| delete(key) }
    self
  end
end

ecsClient = Aws::ECS::Client.new

if(options.fetch(:CREATE, false) || options.fetch(:TEARDOWN, false))
  puts "Fetching services in cluster #{CLUSTER}"
  puts "-> #service/#{SITE_NAME}-#{PR_TAG}"
  services = ecsClient.list_services(cluster: CLUSTER).to_h[:service_arns]
  puts "Checking if existing service for pull request is present"
  services
  .select{|x|  /service\/#{SITE_NAME}-#{PR_TAG}(?:-\d{0,3})?/.match(x)}
  .each do |service_arn|
    name = /service\/(#{SITE_NAME}-#{PR_TAG}(?:-\d{0,3})?)/.match(service_arn)[1]
    puts "Deleting #{service_arn}"
    ecsClient.delete_service({
      cluster: CLUSTER,
      service: name,
      force: true
    })
  end
end



if(options.fetch(:CREATE, false))

  puts SITE_NAME
  BASE_TAG = options.fetch(:BASE_TAG)
  # Get the base tag version
  puts "Getting base task definition"
  base_defintion = ecsClient.describe_task_definition({
    task_definition: "arn:aws:ecs:eu-west-1:280793680319:task-definition/#{SITE_NAME}:#{BASE_TAG}"
  }).to_h

  # update base definition
  puts "Mutating it for current PR"
  task_definition = base_defintion[:task_definition]
  task_definition[:container_definitions] = task_definition[:container_definitions].map do |container_definition|
    unless container_definition[:name] == "Netflexapp" || container_definition[:name] == "Site"
      puts "Not mutating support container"
      container_definition
    else
      puts "Mutating Netflexapp container"
      container_definition[:image] = "280793680319.dkr.ecr.eu-west-1.amazonaws.com/#{REPOSITORY}:#{PR_TAG}"
      container_definition[:docker_labels] = {
        "traefik.frontend.rule": "Host: #{PR_TAG}.#{SITE_NAME == "netflexapp" ? "develop" : "#{SITE_NAME}.site" }.netflexapp.com",
        "traefik.enable": "true"
      }
      container_definition
    end
  end
  task_definition = task_definition.except(:task_definition_arn, :revision, :status, :requires_attributes, :compatibilities)
  task_definition[:family] = SITE_NAME


  puts "Creating new task_definition"
  response = ecsClient.register_task_definition(task_definition)

  new_task_definition = "#{response.to_h[:task_definition][:family]}:#{response.to_h[:task_definition][:revision].to_s}"
  puts "New task definition is #{new_task_definition}"

  puts "Creating new service"
  ecsClient.create_service(
    cluster: CLUSTER,
    desired_count: 1,
    service_name: "#{SITE_NAME}-#{PR_TAG}-#{100 + rand(899)}",
    task_definition: new_task_definition,
    launch_type: "FARGATE",
    network_configuration: {
      awsvpc_configuration: {
        subnets: ["subnet-05573d73"],
        security_groups: ["sg-0465d00b70e358b4d"],
        assign_public_ip: "ENABLED"
      }
    }
  )
  puts "::set-output name=url::" + "#{PR_TAG}.#{SITE_NAME == "netflexapp" ? "develop" : "#{SITE_NAME}.site" }.netflexapp.com"
end

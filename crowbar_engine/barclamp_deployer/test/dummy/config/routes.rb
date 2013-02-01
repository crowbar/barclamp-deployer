Rails.application.routes.draw do

  mount BarclampDeployer::Engine => "/barclamp_deployer"
end

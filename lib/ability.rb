# frozen_string_literal: true

class Ability
  include CanCan::Ability

  def initialize(user)
    return if user.blank?

    can :manage, User, id: user.id
    can :manage, UserConfig, user_id: user.id
    can :manage, EncryptedUserConfig, user_id: user.id
    can :manage, AccessToken, user_id: user.id
    can :manage, McpToken, user_id: user.id

    case user.role
    when User::VIEWER_ROLE
      can :read, Template, Abilities::TemplateConditions.collection(user) do |template|
        Abilities::TemplateConditions.entity(template, user:)
      end
      can :read, TemplateFolder, account_id: user.account_id
      can :read, TemplateSharing, template: { account_id: user.account_id }
      can :read, Submission, account_id: user.account_id
      can :read, Submitter, account_id: user.account_id
      can :read, WebhookUrl, account_id: user.account_id
    when User::EDITOR_ROLE
      can %i[read create update], Template, Abilities::TemplateConditions.collection(user) do |template|
        Abilities::TemplateConditions.entity(template, user:, ability: 'manage')
      end
      can :destroy, Template, account_id: user.account_id
      can :manage, TemplateFolder, account_id: user.account_id
      can :manage, TemplateSharing, template: { account_id: user.account_id }
      can :manage, Submission, account_id: user.account_id
      can :manage, Submitter, account_id: user.account_id
      can :manage, WebhookUrl, account_id: user.account_id
    else
      can %i[read create update], Template, Abilities::TemplateConditions.collection(user) do |template|
        Abilities::TemplateConditions.entity(template, user:, ability: 'manage')
      end
      can :destroy, Template, account_id: user.account_id
      can :manage, TemplateFolder, account_id: user.account_id
      can :manage, TemplateSharing, template: { account_id: user.account_id }
      can :manage, Submission, account_id: user.account_id
      can :manage, Submitter, account_id: user.account_id
      can :manage, User, account_id: user.account_id
      can :manage, EncryptedConfig, account_id: user.account_id
      can :manage, AccountConfig, account_id: user.account_id
      can :manage, Account, id: user.account_id
      can :manage, WebhookUrl, account_id: user.account_id
      can :manage, :mcp
    end
  end
end

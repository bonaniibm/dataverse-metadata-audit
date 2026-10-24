using System;
using System.Collections.Generic;
using System.Linq;
using System.Xml.Linq;
using Microsoft.Xrm.Sdk;

namespace MetadataAudit.Plugins
{
    /// <summary>
    /// Logs every Publish (PublishXmlRequest) and PublishAll (PublishAllXmlRequest) call to the
    /// {prefix}_customizationpublishlog table: who published, when, and which components (ParameterXml).
    ///
    /// Register PostOperation (stage 40), synchronous, on messages "Publish" and "PublishAll", primary entity "none".
    /// Unsecure configuration = customization prefix of the log table (default "mda").
    ///
    /// Logging must never block a maker's publish, so every failure is traced and swallowed.
    /// </summary>
    public class PublishLoggerPlugin : IPlugin
    {
        private const int MaxParameterXmlLength = 1048576;
        private const int MaxSummaryLength = 4000;

        private readonly string _prefix;

        public PublishLoggerPlugin(string unsecureConfig, string secureConfig)
        {
            _prefix = string.IsNullOrWhiteSpace(unsecureConfig) ? "mda" : unsecureConfig.Trim().TrimEnd('_');
        }

        public void Execute(IServiceProvider serviceProvider)
        {
            var tracing = (ITracingService)serviceProvider.GetService(typeof(ITracingService));
            var context = (IPluginExecutionContext)serviceProvider.GetService(typeof(IPluginExecutionContext));

            try
            {
                if (context.MessageName != "Publish" && context.MessageName != "PublishAll")
                {
                    tracing.Trace($"PublishLogger: ignoring message {context.MessageName}");
                    return;
                }

                var factory = (IOrganizationServiceFactory)serviceProvider.GetService(typeof(IOrganizationServiceFactory));
                // SYSTEM context so makers don't need privileges on the log table
                var service = factory.CreateOrganizationService(null);

                string parameterXml = null;
                if (context.InputParameters.Contains("ParameterXml"))
                {
                    parameterXml = context.InputParameters["ParameterXml"] as string;
                }

                var userName = GetUserName(service, context.UserId, tracing);
                var initiatingUserName = context.InitiatingUserId == context.UserId
                    ? userName
                    : GetUserName(service, context.InitiatingUserId, tracing);

                var summary = context.MessageName == "PublishAll"
                    ? "PublishAll: all unpublished customizations (no component list available)"
                    : Summarize(parameterXml);

                var log = new Entity($"{_prefix}_customizationpublishlog");
                log[$"{_prefix}_name"] = Truncate($"{context.MessageName} by {userName} at {DateTime.UtcNow:yyyy-MM-dd HH:mm:ss}Z", 200);
                log[$"{_prefix}_message"] = context.MessageName;
                log[$"{_prefix}_userid"] = context.UserId.ToString();
                log[$"{_prefix}_username"] = Truncate(userName, 200);
                log[$"{_prefix}_initiatinguserid"] = context.InitiatingUserId.ToString();
                log[$"{_prefix}_initiatingusername"] = Truncate(initiatingUserName, 200);
                log[$"{_prefix}_parameterxml"] = Truncate(parameterXml, MaxParameterXmlLength);
                log[$"{_prefix}_summary"] = Truncate(summary, MaxSummaryLength);
                log[$"{_prefix}_correlationid"] = context.CorrelationId.ToString();

                service.Create(log);
                tracing.Trace($"PublishLogger: logged {context.MessageName} by {userName}");
            }
            catch (Exception ex)
            {
                tracing.Trace($"PublishLogger: failed to log publish - {ex}");
            }
        }

        private static string GetUserName(IOrganizationService service, Guid userId, ITracingService tracing)
        {
            try
            {
                var user = service.Retrieve("systemuser", userId, new Microsoft.Xrm.Sdk.Query.ColumnSet("fullname", "domainname"));
                var full = user.GetAttributeValue<string>("fullname");
                var domain = user.GetAttributeValue<string>("domainname");
                return string.IsNullOrEmpty(domain) ? full : $"{full} <{domain}>";
            }
            catch (Exception ex)
            {
                tracing.Trace($"PublishLogger: could not read user {userId} - {ex.Message}");
                return userId.ToString();
            }
        }

        /// <summary>
        /// Turns ParameterXml such as
        ///   &lt;importexportxml&gt;&lt;entities&gt;&lt;entity&gt;account&lt;/entity&gt;&lt;/entities&gt;&lt;webresources&gt;...&lt;/webresources&gt;&lt;/importexportxml&gt;
        /// into "entities: account; webresources: {guid}".
        /// </summary>
        internal static string Summarize(string parameterXml)
        {
            if (string.IsNullOrWhiteSpace(parameterXml)) return "(no ParameterXml)";
            try
            {
                var root = XElement.Parse(parameterXml);
                var parts = new List<string>();
                foreach (var group in root.Elements())
                {
                    var values = group.Elements().Select(e => e.Value.Trim()).Where(v => v.Length > 0).ToList();
                    if (values.Count > 0)
                    {
                        parts.Add($"{group.Name.LocalName}: {string.Join(", ", values)}");
                    }
                }
                return parts.Count == 0 ? "(empty ParameterXml)" : string.Join("; ", parts);
            }
            catch (Exception ex)
            {
                return $"(unparseable ParameterXml: {ex.Message})";
            }
        }

        private static string Truncate(string value, int max)
        {
            if (value == null) return null;
            return value.Length <= max ? value : value.Substring(0, max);
        }
    }
}

package tak.server.plugins.agent;

import java.io.IOException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

import java.util.LinkedList;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

import org.dom4j.DocumentException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import software.amazon.awssdk.auth.credentials.DefaultCredentialsProvider;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.bedrockruntime.BedrockRuntimeClient;
import software.amazon.awssdk.services.bedrockruntime.model.ContentBlock;
import software.amazon.awssdk.services.bedrockruntime.model.ConversationRole;
import software.amazon.awssdk.services.bedrockruntime.model.ConverseRequest;
import software.amazon.awssdk.services.bedrockruntime.model.ConverseResponse;
import software.amazon.awssdk.services.bedrockruntime.model.InferenceConfiguration;
import software.amazon.awssdk.services.bedrockruntime.model.StopReason;
import software.amazon.awssdk.services.bedrockruntime.model.SystemContentBlock;
import software.amazon.awssdk.services.bedrockruntime.model.Tool;
import software.amazon.awssdk.services.bedrockruntime.model.ToolConfiguration;
import software.amazon.awssdk.services.bedrockruntime.model.ToolInputSchema;
import software.amazon.awssdk.services.bedrockruntime.model.ToolResultBlock;
import software.amazon.awssdk.services.bedrockruntime.model.ToolResultContentBlock;
import software.amazon.awssdk.services.bedrockruntime.model.ToolSpecification;
import software.amazon.awssdk.services.bedrockruntime.model.ToolUseBlock;
import software.amazon.awssdk.services.bedrockagentruntime.BedrockAgentRuntimeAsyncClient;
import software.amazon.awssdk.services.bedrockagentruntime.BedrockAgentRuntimeClient;
import software.amazon.awssdk.services.bedrockagentruntime.model.FunctionInvocationInput;
import software.amazon.awssdk.services.bedrockagentruntime.model.FunctionResult;
import software.amazon.awssdk.services.bedrockagentruntime.model.InvocationResultMember;
import software.amazon.awssdk.services.bedrockagentruntime.model.InvokeAgentRequest;
import software.amazon.awssdk.services.bedrockagentruntime.model.KnowledgeBaseRetrieveAndGenerateConfiguration;
import software.amazon.awssdk.services.bedrockagentruntime.model.ResponseStream;
import software.amazon.awssdk.services.bedrockagentruntime.model.ReturnControlPayload;
import software.amazon.awssdk.services.bedrockagentruntime.model.RetrieveAndGenerateConfiguration;
import software.amazon.awssdk.services.bedrockagentruntime.model.RetrieveAndGenerateInput;
import software.amazon.awssdk.services.bedrockagentruntime.model.RetrieveAndGenerateRequest;
import software.amazon.awssdk.services.bedrockagentruntime.model.RetrieveAndGenerateResponse;
import software.amazon.awssdk.services.bedrockagentruntime.model.RetrieveAndGenerateType;
import software.amazon.awssdk.services.bedrockagentruntime.model.SessionState;

import atakmap.commoncommo.protobuf.v1.MessageOuterClass.Message;
import tak.server.plugins.LLMChatManager;
import tak.server.plugins.config.TAKContext;
import tak.server.plugins.messages.CotType;
import tak.server.plugins.messages.TAKMessageGenerator;

public class BedrockChatManager implements LLMChatManager {
    private BedrockRuntimeClient client;
    private BedrockAgentRuntimeAsyncClient agentAsyncClient;
    private BedrockAgentRuntimeClient agentClient;
    private String systemPrompt;
    private String modelId;
    private String knowledgeBaseId;
    private String agentId;
    private String agentAliasId;
    private final int conversationHistorySize;
    private static final long SESSION_IDLE_MS = 30 * 60 * 1000L; // 30 minutes

    private static class ConversationSession {
        final LinkedList<software.amazon.awssdk.services.bedrockruntime.model.Message> history = new LinkedList<>();
        long lastAccessMs = System.currentTimeMillis();
    }
    private final ConcurrentHashMap<String, ConversationSession> conversationSessions = new ConcurrentHashMap<>();
    private static final Logger LOGGER = LoggerFactory.getLogger(BedrockChatManager.class);
    private static final TAKMessageGenerator MSG_GENERATOR = TAKMessageGenerator.getInstance();

    public BedrockChatManager(Map<String, ? extends Object> config) {
        String region = "us-west-2";
        if (config.containsKey("region")) {
            region = (String) config.get("region");
        }

        if (config.containsKey("modelName")) {
            modelId = (String) config.get("modelName");
        } else {
            LOGGER.error("Unable to locate property for modelName in configuration");
            modelId = "anthropic.claude-3-sonnet-20240229-v1:0";
        }

        knowledgeBaseId = config.containsKey("knowledgeBaseId") ? (String) config.get("knowledgeBaseId") : null;
        agentId = config.containsKey("agentId") ? (String) config.get("agentId") : null;
        agentAliasId = config.containsKey("agentAliasId") ? (String) config.get("agentAliasId") : null;
        conversationHistorySize = config.containsKey("conversationHistorySize") ?
                ((Number) config.get("conversationHistorySize")).intValue() : 10;

        String ragPrompt = loadSystemPromptFromConfig(config);
        systemPrompt = (ragPrompt == null ? "You are a helpful assistant." : ragPrompt)
                + "\n\nMessages may be prefixed with [User: <callsign>] or [User: <callsign>, Location: <lat>, <lon>]. When a Location is present, use it to answer location-based questions like 'Where am I?'. If no Location is in the prefix, you do not have the user's location — say so simply without instructing them to configure anything."
                + "\n\nIMPORTANT: When asked to create, place, or add a map marker, you MUST call the create_tak_map_marker tool immediately without asking for clarification. Use these defaults if not specified by the user: type=\"a-f-G\" (friendly ground), callsign=name of the location if a place name was given or \"Chatbot Marker\" if coordinates were given. Do not describe or simulate the action \u2014 invoke the tool directly. After a successful tool call, respond only with 'Marker added'.";

        client = BedrockRuntimeClient.builder()
                .region(Region.of(region))
                .credentialsProvider(DefaultCredentialsProvider.create())
                .build();

        if (agentId != null) {
            agentAsyncClient = BedrockAgentRuntimeAsyncClient.builder()
                    .region(Region.of(region))
                    .credentialsProvider(DefaultCredentialsProvider.create())
                    .build();
        }
        if (knowledgeBaseId != null) {
            agentClient = BedrockAgentRuntimeClient.builder()
                    .region(Region.of(region))
                    .credentialsProvider(DefaultCredentialsProvider.create())
                    .build();
        }

        LOGGER.info("BedrockChatManager initialized with model: {} in region: {}, agent: {}, knowledgeBase: {}", 
                modelId, region, agentId != null ? agentId : "none", knowledgeBaseId != null ? knowledgeBaseId : "none");
    }

    private ToolSpecification createToolSpecification() {
        // Build JSON schema using Document API
        software.amazon.awssdk.core.document.Document schema = 
            software.amazon.awssdk.core.document.Document.fromMap(Map.of(
                "type", software.amazon.awssdk.core.document.Document.fromString("object"),
                "properties", software.amazon.awssdk.core.document.Document.fromMap(Map.of(
                    "type", software.amazon.awssdk.core.document.Document.fromMap(Map.of(
                        "type", software.amazon.awssdk.core.document.Document.fromString("string"),
                        "description", software.amazon.awssdk.core.document.Document.fromString("The type of marker to create. Types are specified as strings of characters with dashes between them, for example a-h-G, or from this set of values: 'hostile ground', 'friendly ground', 'neutral ground', 'unknown ground', 'hostile air', 'friendly air', 'neutral air', 'unknown air'")
                    )),
                    "callsign", software.amazon.awssdk.core.document.Document.fromMap(Map.of(
                        "type", software.amazon.awssdk.core.document.Document.fromString("string"),
                        "description", software.amazon.awssdk.core.document.Document.fromString("The callsign of the marker to create")
                    )),
                    "lat", software.amazon.awssdk.core.document.Document.fromMap(Map.of(
                        "type", software.amazon.awssdk.core.document.Document.fromString("string"),
                        "description", software.amazon.awssdk.core.document.Document.fromString("The latitude of the marker")
                    )),
                    "lon", software.amazon.awssdk.core.document.Document.fromMap(Map.of(
                        "type", software.amazon.awssdk.core.document.Document.fromString("string"),
                        "description", software.amazon.awssdk.core.document.Document.fromString("The longitude of the marker")
                    ))
                )),
                "required", software.amazon.awssdk.core.document.Document.fromList(
                    List.of(
                        software.amazon.awssdk.core.document.Document.fromString("type"),
                        software.amazon.awssdk.core.document.Document.fromString("callsign"),
                        software.amazon.awssdk.core.document.Document.fromString("lat"),
                        software.amazon.awssdk.core.document.Document.fromString("lon")
                    )
                )
            ));
        
        return ToolSpecification.builder()
                .name("create_tak_map_marker")
                .description("Create a map marker in TAK. This is not for interacting with the Google Maps API, but for interacting with the TAK map which is unrelated to Google Maps.")
                .inputSchema(ToolInputSchema.builder()
                        .json(schema)
                        .build())
                .build();
    }

    private String buildContextualMessage(String messageText, TAKContext context) {
        if (context == null || context.getCallsign() == null) return messageText;
        boolean hasLocation = context.getLat() != null && context.getLon() != null;
        if (hasLocation) {
            return String.format("[User: %s, Location: %s, %s] %s",
                    context.getCallsign(), context.getLat(), context.getLon(), messageText);
        } else {
            return String.format("[User: %s] %s", context.getCallsign(), messageText);
        }
    }

    private Map<String, String> createMarker(String type, String callsign, String lat, String lon, Set<String> groups) {
        LOGGER.debug("createMarker called");
        Map<String, String> map = new HashMap<>();

        String cotType;
        if (type.contains("-")) {
            cotType = type;
        } else {
            try {
                CotType cotTypeValue = CotType.valueOf(type.toUpperCase().replace(" ", "_"));
                cotType = cotTypeValue.getType();
            } catch (IllegalArgumentException e) {
                LOGGER.error("Invalid marker type: " + type);
                map.put("status", "failure");
                map.put("report", "Invalid CotType: " + type);
                return map;
            }
        }

        try {
            Message msg = MSG_GENERATOR.generateMarker(cotType, callsign, Float.valueOf(lat), Float.valueOf(lon), groups);
            MSG_GENERATOR.send(msg);
            map.put("status", "success");
            map.put("report", "Created a marker of type: " + type + ", callsign: " + callsign + ", at lat: " + lat + ", lon: " + lon);
            LOGGER.debug("Created new map marker message: " + msg.toString());
        } catch (DocumentException e) {
            LOGGER.error("Exception creating message to send", e);
            map.put("status", "failure");
            map.put("report", "Unable to create marker");
        }

        return map;
    }

    @Override
    public String sendChatRequest(String messageText, TAKContext context) throws IOException {
        if (agentId != null) {
            return sendAgentRequest(messageText, context);
        } else if (knowledgeBaseId != null) {
            return sendKnowledgeBaseRequest(messageText, context);
        }
        try {
            String sessionId = context != null ? context.getSessionId() : null;
            ConversationSession session = null;
            if (sessionId != null) {
                session = conversationSessions.compute(sessionId, (k, v) -> {
                    if (v == null || System.currentTimeMillis() - v.lastAccessMs > SESSION_IDLE_MS) {
                        return new ConversationSession();
                    }
                    v.lastAccessMs = System.currentTimeMillis();
                    return v;
                });
            }
            final ConversationSession activeSession = session;

            List<software.amazon.awssdk.services.bedrockruntime.model.Message> conversation = new ArrayList<>();
            if (activeSession != null) {
                conversation.addAll(activeSession.history);
            }
            
            // Build context-aware user message
            String contextualMessage = buildContextualMessage(messageText, context);
            
            // Add user message
            conversation.add(software.amazon.awssdk.services.bedrockruntime.model.Message.builder()
                    .role(ConversationRole.USER)
                    .content(ContentBlock.fromText(contextualMessage))
                    .build());
            
            // Tool configuration
            ToolConfiguration toolConfig = ToolConfiguration.builder()
                    .tools(Tool.builder()
                            .toolSpec(createToolSpecification())
                            .build())
                    .build();
            
            // Tool use loop (max 5 iterations)
            for (int i = 0; i < 5; i++) {
                LOGGER.debug("Converse iteration {}", i + 1);
                
                ConverseRequest request = ConverseRequest.builder()
                        .modelId(modelId)
                        .messages(conversation)
                        .system(SystemContentBlock.builder()
                                .text(systemPrompt)
                                .build())
                        .toolConfig(toolConfig)
                        .inferenceConfig(InferenceConfiguration.builder()
                                .maxTokens(2048)
                                .temperature(0.7f)
                                .build())
                        .build();

                ConverseResponse response = client.converse(request);
                
                LOGGER.debug("Stop reason: {}", response.stopReason());
                
                // Add assistant response to conversation
                conversation.add(response.output().message());
                
                if (response.stopReason() == StopReason.TOOL_USE) {
                    // Process tool use
                    List<ContentBlock> toolResults = new ArrayList<>();
                    
                    for (ContentBlock contentBlock : response.output().message().content()) {
                        if (contentBlock.toolUse() != null) {
                            ToolUseBlock toolUse = contentBlock.toolUse();
                            String toolName = toolUse.name();
                            String toolUseId = toolUse.toolUseId();
                            
                            LOGGER.debug("Tool use: {} (ID: {})", toolName, toolUseId);
                            
                            if ("create_tak_map_marker".equals(toolName)) {
                                // Parse input from Document
                                software.amazon.awssdk.core.document.Document input = toolUse.input();
                                String type = input.asMap().get("type").asString();
                                String callsign = input.asMap().get("callsign").asString();
                                String lat = input.asMap().get("lat").asString();
                                String lon = input.asMap().get("lon").asString();
                                
                                // Execute tool
                                Map<String, String> result = createMarker(type, callsign, lat, lon,
                                        context != null ? context.getGroups() : null);
                                
                                // Add tool result
                                toolResults.add(ContentBlock.builder()
                                        .toolResult(ToolResultBlock.builder()
                                                .toolUseId(toolUseId)
                                                .content(ToolResultContentBlock.fromText(
                                                        String.format("{\"status\":\"%s\",\"report\":\"%s\"}",
                                                                result.get("status"),
                                                                result.get("report"))))
                                                .build())
                                        .build());
                            }
                        }
                    }
                    
                    if (!toolResults.isEmpty()) {
                        // Add tool results to conversation
                        conversation.add(software.amazon.awssdk.services.bedrockruntime.model.Message.builder()
                                .role(ConversationRole.USER)
                                .content(toolResults)
                                .build());
                        continue;
                    }
                    
                } else if (response.stopReason() == StopReason.END_TURN) {
                    // Extract final text response
                    for (ContentBlock contentBlock : response.output().message().content()) {
                        if (contentBlock.text() != null) {
                            if (activeSession != null) {
                                // Persist the user message and assistant response
                                activeSession.history.add(conversation.get(conversation.size() - 2)); // user msg
                                activeSession.history.add(response.output().message()); // assistant msg
                                // Trim to max history (pairs of user+assistant = 2 messages each)
                                while (activeSession.history.size() > conversationHistorySize * 2) {
                                    activeSession.history.removeFirst();
                                    activeSession.history.removeFirst();
                                }
                            }
                            return contentBlock.text();
                        }
                    }
                }
                
                break;
            }

            LOGGER.warn("No text response found");
            return "Error: Unable to get response from AI model";

        } catch (Exception e) {
            LOGGER.error("Exception while calling Bedrock", e);
            return "Error while talking to bot: " + e.getMessage();
        }
    }

    private String sendAgentRequest(String messageText, TAKContext context) throws IOException {
        try {
            String contextualMessage = buildContextualMessage(messageText, context);
            String sessionId = context != null && context.getSessionId() != null
                    ? context.getSessionId().replaceAll("[^a-zA-Z0-9_-]", "-")
                    : "tak-session-" + System.currentTimeMillis();

            SessionState sessionState = null;

            // Loop to handle RETURN_CONTROL (max 5 tool calls)
            for (int i = 0; i < 5; i++) {
                InvokeAgentRequest.Builder requestBuilder = InvokeAgentRequest.builder()
                        .agentId(agentId)
                        .agentAliasId(agentAliasId != null ? agentAliasId : "TSTALIASID")
                        .sessionId(sessionId)
                        .inputText(i == 0 ? contextualMessage : "");
                if (sessionState != null) {
                    requestBuilder.sessionState(sessionState);
                }

                StringBuilder result = new StringBuilder();
                final ReturnControlPayload[] returnControl = {null};

                agentAsyncClient.invokeAgent(requestBuilder.build(),
                        software.amazon.awssdk.services.bedrockagentruntime.model.InvokeAgentResponseHandler.builder()
                                .subscriber(software.amazon.awssdk.services.bedrockagentruntime.model.InvokeAgentResponseHandler.Visitor.builder()
                                        .onChunk(chunk -> result.append(chunk.bytes().asUtf8String()))
                                        .onReturnControl(rc -> returnControl[0] = rc)
                                        .build())
                                .build())
                        .join();

                if (returnControl[0] == null) {
                    return result.toString();
                }

                // Handle RETURN_CONTROL — execute tool and loop back
                List<InvocationResultMember> invocationResults = new ArrayList<>();
                for (FunctionInvocationInput invocation : returnControl[0].invocationInputs().stream()
                        .filter(ii -> ii.functionInvocationInput() != null)
                        .map(ii -> ii.functionInvocationInput())
                        .collect(Collectors.toList())) {

                    String functionName = invocation.function();
                    Map<String, String> params = new HashMap<>();
                    invocation.parameters().forEach(p -> params.put(p.name(), p.value()));

                    String toolResult;
                    if ("create_tak_map_marker".equals(functionName)) {
                        Map<String, String> markerResult = createMarker(
                                params.get("type"), params.get("callsign"),
                                params.get("lat"), params.get("lon"),
                                context != null ? context.getGroups() : null);
                        toolResult = String.format("{\"status\":\"%s\",\"report\":\"%s\"}",
                                markerResult.get("status"), markerResult.get("report"));
                    } else {
                        toolResult = "{\"status\":\"error\",\"report\":\"Unknown function: " + functionName + "\"}"; 
                    }

                    invocationResults.add(InvocationResultMember.builder()
                            .functionResult(FunctionResult.builder()
                                    .actionGroup(invocation.actionGroup())
                                    .function(functionName)
                                    .responseBody(Map.of("TEXT",
                                            software.amazon.awssdk.services.bedrockagentruntime.model.ContentBody.builder()
                                                    .body(toolResult).build()))
                                    .build())
                            .build());
                }

                sessionState = SessionState.builder()
                        .invocationId(returnControl[0].invocationId())
                        .returnControlInvocationResults(invocationResults)
                        .build();
            }

            LOGGER.warn("Agent RETURN_CONTROL loop exceeded max iterations");
            return "Error: tool call loop exceeded";

        } catch (Exception e) {
            LOGGER.error("Exception while calling Bedrock Agent", e);
            return "Error while talking to bot: " + e.getMessage();
        }
    }

    private String sendKnowledgeBaseRequest(String messageText, TAKContext context) throws IOException {
        try {
            String contextualMessage = buildContextualMessage(messageText, context);

            RetrieveAndGenerateRequest request = RetrieveAndGenerateRequest.builder()
                    .input(RetrieveAndGenerateInput.builder()
                            .text(contextualMessage)
                            .build())
                    .retrieveAndGenerateConfiguration(RetrieveAndGenerateConfiguration.builder()
                            .type(RetrieveAndGenerateType.KNOWLEDGE_BASE)
                            .knowledgeBaseConfiguration(KnowledgeBaseRetrieveAndGenerateConfiguration.builder()
                                    .knowledgeBaseId(knowledgeBaseId)
                                    .modelArn("arn:aws:bedrock:" + client.serviceClientConfiguration().region() + "::foundation-model/" + modelId)
                                    .build())
                            .build())
                    .build();

            RetrieveAndGenerateResponse response = agentClient.retrieveAndGenerate(request);
            return response.output().text();

        } catch (Exception e) {
            LOGGER.error("Exception while calling Bedrock Knowledge Base", e);
            return "Error while talking to bot: " + e.getMessage();
        }
    }
}

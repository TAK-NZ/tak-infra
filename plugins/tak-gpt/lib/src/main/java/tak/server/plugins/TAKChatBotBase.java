package tak.server.plugins;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import static java.util.concurrent.Executors.newScheduledThreadPool;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

import javax.xml.parsers.DocumentBuilderFactory;

import org.dom4j.Document;
import org.dom4j.DocumentException;
import org.dom4j.Node;
import org.dom4j.io.SAXReader;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import atakmap.commoncommo.protobuf.v1.MessageOuterClass.Message;
import tak.server.cot.CotEventContainer;
import tak.server.proto.StreamingProtoBufHelper;
import tak.server.plugins.agent.AnthropicChatManager;
import tak.server.plugins.agent.BedrockChatManager;
import tak.server.plugins.agent.GoogleAgentChatManager;
import tak.server.plugins.agent.OllamaChatManager;
import tak.server.plugins.agent.OpenAIAPIChatManager;
import tak.server.plugins.config.TAKContext;
import tak.server.plugins.messages.TAKChatGenerator;
import tak.server.plugins.messages.TAKMessageGenerator;

@TakServerPlugin(name="TAK GPT", description="This plugin serves as the base for LLM-backed TAK chat bots")
/**
 * TAK GPT Plugin - this serves as a common message router for all bots/agents
 * 
 * Configuration:
 * bots : a list of configuration properties for all bots
 *     - modelType
 * 	   - botName
 *     - groups
 *     - latitude
 *     - longitude
 */
public class TAKChatBotBase extends MessageSenderReceiverBase {
	private static final Logger LOGGER = LoggerFactory.getLogger(TAKChatBotBase.class);
	private static final String CALLSIGN_MSG_MARKER = "dest callsign=\"";
	private final ScheduledExecutorService scheduler;
	private List<TAKBOTPresenceBroadcaster> broadcasters = new ArrayList();
	
	private Runnable broadcastTask = new Thread() {
		@Override
		public void run() {
			for(TAKBOTPresenceBroadcaster broadcaster : broadcasters) {
				try {
					LOGGER.debug("Sending new presence message");
					Message msg = broadcaster.generatePresenceMessage();
					
					send(msg);
				} catch (DocumentException e) {
					LOGGER.error("Unable to generate new presence message for TAK bot", e );
				}
			}
		}
	};
	
	public TAKChatBotBase() {
		scheduler = newScheduledThreadPool(1);
	}
	
	private Map<String, LLMChatManager> llmManagers = new HashMap<>();
	
	@Override
	public void start() {
		LOGGER.info("Starting up TAK GPT Plugin");
		TAKMessageGenerator.getInstance().init(getConverter(), this);

		List<? extends Object> bots = (List<? extends Object>)config.getProperty("bots");
		for(Object botObj : bots) {
			Map<String, ? extends Object> bot = (Map<String, ? extends Object>)botObj;
			
			String modelType = (String)bot.get("modelType");
			String botName = (String)bot.get("botName");

			List<String> groups = (List<String>)bot.get("groups");
			LOGGER.info("Bot with name " + botName + " should use groups: " + groups);

			// ** get lat and lon for where the bot/agent should show up
			Double botLatitude = 0.0;
			if(bot.containsKey("latitude")) {
				botLatitude = (Double)bot.get("latitude");
			}
			Double botLongitude = 0.0;
			if(bot.containsKey("longitude")) {
				botLongitude = (Double)bot.get("longitude");
			}
			
			// ** get display group name, role, and CoT type
			String groupName = bot.containsKey("groupName") ? (String)bot.get("groupName") : null;
			String role = bot.containsKey("role") ? (String)bot.get("role") : null;
			String cotType = bot.containsKey("cotType") ? (String)bot.get("cotType") : null;
			
			broadcasters.add(new TAKBOTPresenceBroadcaster(botName, botLatitude, botLongitude, groups, groupName, role, cotType));
			switch(modelType) {
				case "ollama":
					llmManagers.put(botName, new OllamaChatManager(bot));
					break;
				case "anthropic":
					llmManagers.put(botName, new AnthropicChatManager(bot));
					break;
				case "openai":
					llmManagers.put(botName, new OpenAIAPIChatManager(bot));
					break;
				case "bedrock":
					llmManagers.put(botName, new BedrockChatManager(bot));
					break;
				case "google-agent":
					llmManagers.put(botName, new GoogleAgentChatManager(bot));
					break;
				default:
					LOGGER.warn("Unhandled model type: " + modelType + ". Ignoring.");
			}
		}
		
		scheduler.scheduleAtFixedRate(broadcastTask, 1, 8, TimeUnit.SECONDS);
		LOGGER.info("TAK GPT Plugin started");
	}

	@Override
	public void stop() {
		// TODO Auto-generated method stub
		
	}

	@Override
	public void onMessage(Message msg) {
		CotEventContainer cec = StreamingProtoBufHelper.proto2cot(msg.getPayload());
		LOGGER.debug("\n\nReceived CoT Message:\n" + cec.asXml() + "\n\n");

		if(isChat(msg) && isSentToTAKBot(msg)) {
			String botName = getDestinationCallsign(msg);
			LLMChatManager llmChatMgr = llmManagers.get(botName);

			DocumentBuilderFactory dbf 
            = DocumentBuilderFactory.newInstance(); 
	       
			SAXReader reader = new SAXReader();
	         Document document;
			try {
				TAKContext context = new TAKContext();
				String lat = cec.getLat();
				String lon = cec.getLon();
				String chatUid = msg.getPayload().getCotEvent().getUid();
				String senderCallsign = getSenderCallsign(msg);
				LOGGER.info("Chat message from uid='{}' callsign='{}' lat='{}' lon='{}'", chatUid, senderCallsign, lat, lon);
				if (lat != null && !lat.equals("0.0") && lon != null && !lon.equals("0.0")) {
					context.setLat(lat);
					context.setLon(lon);
				} else {
					LOGGER.info("No location in chat message for '{}'", senderCallsign != null ? senderCallsign : chatUid);
				}
				context.setCallsign(senderCallsign != null ? senderCallsign : chatUid);
				context.setGroups(new java.util.HashSet<>(msg.getGroupsList()));
				context.setSessionId(botName + ":" + context.getCallsign());

				
				document = reader.read(new ByteArrayInputStream(("<event>" + msg.getPayload().getCotEvent().getDetail().getXmlDetail() + "</event>").getBytes()) );
		         List<Node> nodes = document.selectNodes("/event/remarks" );
		         if(!nodes.isEmpty()) {
		        	 String text = nodes.get(0).getText();
		        	 LOGGER.info("Sending message to LLM: " + text);
		        	 String response = null;
		        	 int counter = 0;
		        	 
		        	 while(counter++ < 2 && response == null) {
			        	 try {
			 				response = llmChatMgr.sendChatRequest(text, context);
			 			} catch (Exception e) {
			 				LOGGER.error("Error sending chat request to LLM (request attempt " + counter + " of 2", e);
			 			}
		        	 }
		        	 
		        	 if(response == null) {
		        		 response = "Error sending chat request to LLM";
		        	 }
		        	 
		        	Message newMessage = TAKChatGenerator.generateChat(msg, response, botName);
		        	LOGGER.info("Sending response chat message: " + newMessage.toString());
		 			send(newMessage);
		 			LOGGER.info("Sent response chat message");
		         }
			} catch (DocumentException e) {
				LOGGER.error("Unable to parse CoT remarks element", e);
			} catch (Exception e) {
				LOGGER.error("Error while generating or sending response chat mesage", e);
			}
	         

		}
	}

	private static final String SENDER_CALLSIGN_MARKER = "senderCallsign=\"";

	private String getSenderCallsign(Message msg) {
		try {
			String detail = msg.getPayload().getCotEvent().getDetail().getXmlDetail();
			int start = detail.indexOf(SENDER_CALLSIGN_MARKER) + SENDER_CALLSIGN_MARKER.length();
			int end = detail.indexOf('"', start);
			if (start > SENDER_CALLSIGN_MARKER.length() - 1 && end > start) return detail.substring(start, end);
		} catch (Exception e) { /* ignore */ }
		return null;
	}

	private boolean isSentToTAKBot(Message msg) {
		return llmManagers.containsKey(getDestinationCallsign(msg));
	}

	private String getDestinationCallsign(Message msg) {
		String callsign = "";
		try {
			String detail = msg.getPayload().getCotEvent().getDetail().getXmlDetail();
			int startIndex = detail.indexOf(CALLSIGN_MSG_MARKER) + CALLSIGN_MSG_MARKER.length();
			int endIndex = detail.indexOf("\"", startIndex);
			callsign = detail.substring(startIndex, endIndex);
		} catch (Exception e) {
			// ** not a chat message with a callsign that we could find
			LOGGER.warn("Unable to find callsign in message: " + e.getMessage());
		}

		LOGGER.debug("Got message for " + callsign);
		return callsign;
	}

	private boolean isChat(Message msg) {
		String cotType = msg.getPayload().getCotEvent().getType();
		
		LOGGER.debug("Received message of type " + cotType);
		
		return "b-t-f".equalsIgnoreCase(cotType);
	}

}

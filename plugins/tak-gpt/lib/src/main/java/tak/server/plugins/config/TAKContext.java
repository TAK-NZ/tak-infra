package tak.server.plugins.config;

import java.util.Set;

public class TAKContext {
    private String lat;
    private String lon;
    private String callsign;
    private String senderUid;
    private Set<String> groups;
    private String sessionId;

    public String getLat() {
        return lat;
    }

    public void setLat(String lat) {
        this.lat = lat;
    }

    public String getLon() {
        return lon;
    }

    public void setLon(String lon) {
        this.lon = lon;
    }

    public String getCallsign() {
        return callsign;
    }

    public void setCallsign(String callsign) {
        this.callsign = callsign;
    }

    /**
     * The sender's stable device UID (e.g. Android device UID, WinTAK user SID),
     * as opposed to callsign which is a mutable display name. This mirrors how
     * ATAK/TAK Server treat UID as the canonical identity for addressing and
     * session/contact tracking, with callsign used only for display purposes.
     */
    public String getSenderUid() {
        return senderUid;
    }

    public void setSenderUid(String senderUid) {
        this.senderUid = senderUid;
    }

    public Set<String> getGroups() {
        return groups;
    }

    public void setGroups(Set<String> groups) {
        this.groups = groups;
    }

    public String getSessionId() {
        return sessionId;
    }

    public void setSessionId(String sessionId) {
        this.sessionId = sessionId;
    }
}

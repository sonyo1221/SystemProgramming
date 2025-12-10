/*  
 comment_editor_final.c  
 - 개발자 모드 / 리뷰 모드 / 복구 모드 포함  
 - strdup 오류 해결  
*/

#define _POSIX_C_SOURCE 200809L
#define SAFE_FREE(p) do { if ((p) != NULL) { free(p); (p) = NULL; } } while(0)
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <ctype.h>
#include <errno.h>
#include <windows.h>

/* strdup가 없는 환경(MinGW 등)을 위한 안전 정의 */
#ifndef HAVE_STRDUP
char *strdup(const char *src) {
    size_t len = strlen(src);
    char *dst = malloc(len + 1);
    if (!dst) return NULL;
    memcpy(dst, src, len + 1);
    return dst;
}
#endif

/* ANSI COLORS */
#define C_RESET   "\033[0m"
#define C_TODO    "\033[33m"
#define C_FIXME   "\033[31m"
#define C_NOTE    "\033[36m"
#define C_NUMBER  "\033[35m"
#define C_SUGGEST "\033[93m"
#define C_COMMENT "\033[32m"

typedef struct {
    char **lines;
    int count;
} LineBuffer;

/* ===============================
   파일 I/O
   =============================== */
static long file_size(const char *p) {
    struct stat st;
    return (stat(p,&st)==0) ? st.st_size : -1;
}

static int copy_file(const char *src, const char *dst) {
    int s = open(src, O_RDONLY);
    if (s < 0) {
        perror("백업: 원본 open 실패");
        return -1;
    }

    int d = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (d < 0) {
        perror("백업: 백업파일 open 실패");
        close(s);
        return -1;
    }

    char buf[4096];
    ssize_t r;
    while ((r = read(s, buf, sizeof(buf))) > 0) {
        if (write(d, buf, r) != r) {
            perror("백업: write 실패");
            close(s);
            close(d);
            return -1;
        }
    }

    if (r < 0) perror("백업: read 실패");

    close(s);
    close(d);
    return (r < 0) ? -1 : 0;
}


static void backup_file(const char *filename) {

    char bak[512];

    /* 절대 경로 생성 */
    char fullpath[512];
    _fullpath(fullpath, filename, sizeof(fullpath));

    snprintf(bak, sizeof(bak), "%s.bak", fullpath);

    printf("[DEBUG] 원본 절대경로: %s\n", fullpath);
    printf("[DEBUG] 백업 파일 경로: %s\n", bak);

    if (copy_file(fullpath, bak) == 0) {
        printf("[백업 완료] %s → %s\n", fullpath, bak);
    } else {
        printf("[백업 실패]\n");
        perror("copy_file 실패 원인");
    }

    Sleep(600);
}


static char *read_whole_file(const char *path){
    long sz = file_size(path);
    if (sz<0) return NULL;

    FILE *f=fopen(path,"r");
    if(!f) return NULL;

    char *buf=malloc(sz+1);
    size_t r=fread(buf,1,sz,f);
    buf[r]='\0';
    fclose(f);
    return buf;
}

static int write_whole_file(const char *path,const char *c){
    FILE *f=fopen(path,"w");
    if(!f) return -1;
    fputs(c,f);
    fclose(f);
    return 0;
}

/* ===============================
   Levenshtein + 사전
   =============================== */
static int levenshtein(const char *a,const char *b){
    int n=strlen(a), m=strlen(b);
    int *prev=malloc((m+1)*4), *curr=malloc((m+1)*4);

    for(int j=0;j<=m;j++) prev[j]=j;

    for(int i=1;i<=n;i++){
        curr[0]=i;
        for(int j=1;j<=m;j++){
            int cost=(a[i-1]==b[j-1])?0:1;
            int ins = curr[j-1] + 1;
            int del = prev[j]   + 1;
            int sub = prev[j-1] + cost;
            int v = ins;
            if(del<v)v=del;
            if(sub<v)v=sub;
            curr[j]=v;
        }
        int *tmp=prev; prev=curr; curr=tmp;
    }

    int res=prev[m];
    free(prev); free(curr);
    return res;
}

static const char *DICT[]={
 "auto","break","case","char","const","continue","default","do","double","else",
 "enum","extern","float","for","goto","if","inline","int","long","register","return",
 "sizeof","static","struct","switch","typedef","union","unsigned","void","volatile",
 "printf","scanf","malloc","free","memcpy","strcmp","strlen",
 "TODO","FIXME","NOTE"
};
static const int DICT_N=sizeof(DICT)/sizeof(DICT[0]);

static int in_dict(const char *t){
    for(int i=0;i<DICT_N;i++) if(!strcmp(t,DICT[i])) return 1;
    return 0;
}

static const char *best_suggest(const char *tok){
    int best=99; const char *pick=NULL;
    for(int i=0;i<DICT_N;i++){
        int d=levenshtein(tok,DICT[i]);
        if(d<best){ best=d; pick=DICT[i]; }
    }
    return (best<=2)? pick : NULL;
}

/* ===============================
   LineBuffer 변환
   =============================== */
static LineBuffer *lines_from_string(const char *c){
    LineBuffer *lb = malloc(sizeof(LineBuffer));
    lb->lines=NULL; lb->count=0;

    const char *p=c;
    while(*p){
        const char *s=p;
        while(*p && *p!='\n') p++;
        int len=p-s;
        char *L=malloc(len+1);
        memcpy(L,s,len); L[len]='\0';

        lb->lines=realloc(lb->lines,sizeof(char*)*(lb->count+1));
        lb->lines[lb->count++]=L;

        if(*p=='\n') p++;
    }
    return lb;
}

static char *string_from_lines(LineBuffer *lb){
    size_t tot=0;
    for(int i=0;i<lb->count;i++) tot+=strlen(lb->lines[i])+1;

    char *buf=malloc(tot+1);
    size_t pos=0;
    for(int i=0;i<lb->count;i++){
        size_t len=strlen(lb->lines[i]);
        memcpy(buf+pos, lb->lines[i], len);
        pos+=len;
        buf[pos++]='\n';
    }
    buf[pos]='\0';
    return buf;
}

static void free_lb(LineBuffer *lb){
    for(int i=0;i<lb->count;i++) free(lb->lines[i]);
    free(lb->lines); free(lb);
}

/* ===============================
   줄 출력(리뷰/개발 공통)
   =============================== */
typedef enum { PM_REVIEW, PM_DEV } PMode;

static void print_line(const char *line,int ln,PMode mode,FILE *log){
    printf(C_NUMBER "%3d | " C_RESET, ln);

    const char *sl=strstr(line,"//"), *bl=strstr(line,"/*");
    int cpos=-1;
    if(sl) cpos = sl-line;
    if(bl && (!sl || bl<sl)) cpos = bl-line;

    char tok[256];
    int t=0, in_tok=0, in_cmt=0;

    for(int i=0; line[i]; ){
        if(!strncmp(&line[i],"TODO",4)){ printf(C_TODO"TODO"C_RESET); i+=4; continue; }
        if(!strncmp(&line[i],"FIXME",5)){printf(C_FIXME"FIXME"C_RESET);i+=5;continue;}
        if(!strncmp(&line[i],"NOTE",4)){ printf(C_NOTE"NOTE"C_RESET); i+=4; continue;}

        unsigned char c=line[i];
        if(isalnum(c)||c=='_'){
            if(!in_tok){ in_tok=1; t=0; in_cmt = (cpos>=0 && i>=cpos); }
            tok[t++]=c; i++;
        } else {
            if(in_tok){
                tok[t]='\0';
                if(in_cmt) printf(C_COMMENT"%s"C_RESET,tok);
                else printf("%s",tok);

                if(mode==PM_DEV && in_cmt && !in_dict(tok)){
                    const char *sg = best_suggest(tok);
                    if(sg){
                        printf(" "C_SUGGEST"/* %s→%s */"C_RESET,tok,sg);
                        if(log) fprintf(log,"[%d] %s->%s\n",ln,tok,sg);
                    }
                }
                in_tok=0; t=0;
            }
            if(cpos>=0 && i>=cpos)
                printf(C_COMMENT"%c"C_RESET,c);
            else putchar(c);
            i++;
        }
    }
    if(in_tok){
        tok[t]='\0';
        if(in_cmt) printf(C_COMMENT"%s"C_RESET,tok);
        else printf("%s",tok);
    }
    putchar('\n');
}
/* ============================================================
   개발자 모드 기능들
   ============================================================ */

   static void dev_show_buffer(LineBuffer *lb){
    printf("\n=== [개발자] 현재 코드 보기 ===\n\n");
    for(int i=0;i<lb->count;i++)
        print_line(lb->lines[i], i+1, PM_REVIEW, NULL);

    printf("\n(위 줄 번호를 참고하여 기능 1번을 사용할 수 있습니다.)\n");
    Sleep(1200);
}

/* 1) 특정 줄에 주석 추가 */
static void dev_add_comment(LineBuffer *lb){
    char buf[32];
    printf("주석을 추가할 줄 번호 입력 (1~%d): ", lb->count);
    if(!fgets(buf,sizeof(buf),stdin)) return;

    int ln = atoi(buf);
    if(ln<1 || ln>lb->count){
        printf("[오류] 잘못된 줄 번호입니다.\n");
        Sleep(900);
        return;
    }

    printf("추가할 주석 입력:\n> ");
    char cmt[512];
    if(!fgets(cmt,sizeof(cmt),stdin)) return;
    cmt[strcspn(cmt,"\n")] = '\0';

    if(!cmt[0]){
        printf("[안내] 빈 문자열은 주석으로 추가되지 않습니다.\n");
        Sleep(900);
        return;
    }

    char *old = lb->lines[ln-1];
    size_t newlen = strlen(old) + strlen(cmt) + 5;
    char *nw = malloc(newlen+1);

    sprintf(nw, "%s // %s", old, cmt);
    lb->lines[ln-1] = nw;
    free(old);

    printf("[개발자] 주석 추가 완료!\n");
    Sleep(1100);
}

/* 함수 정의 판별 */
static int looks_like_func(const char *s){
    while(*s==' '||*s=='\t') s++;
    if(!*s) return 0;

    if(!strncmp(s,"if",2)||!strncmp(s,"for",3)||!strncmp(s,"while",5)||!strncmp(s,"switch",6))
        return 0;

    if(strstr(s,";")) return 0;

    const char *lp=strchr(s,'(');
    const char *rp=strchr(s,')');
    const char *cb=strchr(s,'{');
    if(!lp||!rp||!cb) return 0;
    if(lp>rp||rp>cb) return 0;

    return 1;
}

/* 2) 자동 주석 템플릿 삽입 */
static void dev_auto_comment(LineBuffer *lb){
    int added = 0;

    for(int i=0;i<lb->count;i++){
        char *line = lb->lines[i];
        const char *p=line;
        while(*p==' '||*p=='\t') p++;
        if(!*p) continue;

        if(looks_like_func(p)){
            if(i>0 && strstr(lb->lines[i-1],"Function:")) continue;

            const char *lp=strchr(p,'(');
            const char *name_end = lp-1;

            while(name_end>p && (isalnum(*name_end)||*name_end=='_')) name_end--;
            name_end++;

            int len = strchr(p,'(') - name_end;

            char fname[128];
            memcpy(fname,name_end,len);
            fname[len]='\0';

            int indent = p-line;
            char ind[64];
            memcpy(ind,line,indent);
            ind[indent]='\0';

            char c0[256], c1[256], c2[256], c3[256];
            snprintf(c0,sizeof(c0),"%s/*",ind);
            snprintf(c1,sizeof(c1),"%s * Function: %s",ind,fname);
            snprintf(c2,sizeof(c2),"%s * TODO   : 설명 작성",ind);
            snprintf(c3,sizeof(c3),"%s */",ind);

            lb->lines = realloc(lb->lines,sizeof(char*)*(lb->count+4));
            memmove(&lb->lines[i+4],&lb->lines[i],(lb->count - i)*sizeof(char*));

            lb->lines[i]   = strdup(c0);
            lb->lines[i+1] = strdup(c1);
            lb->lines[i+2] = strdup(c2);
            lb->lines[i+3] = strdup(c3);

            lb->count += 4;
            i += 4;
            added++;
        }
    }

    if(added)
        printf("[개발자] %d개의 함수에 자동 주석 템플릿 추가됨!\n", added);
    else
        printf("[개발자] 자동 주석 삽입할 함수 정의 발견되지 않음\n");

    Sleep(1200);
}

/* 3) 하이라이트 + 오타 감지 */
static void dev_highlight(LineBuffer *lb, const char *filename){
    FILE *log=fopen("dev_log.txt","a");
    if(log) fprintf(log,"=== Highlight session (%s) ===\n",filename);

    printf("\n=== [개발자] 하이라이트 / 오타 제안 ===\n\n");

    for(int i=0;i<lb->count;i++)
        print_line(lb->lines[i], i+1, PM_DEV, log);

    if(log){
        fprintf(log,"=== End session ===\n\n");
        fclose(log);
        printf("[로그] dev_log.txt 에 기록되었습니다.\n");
    }
    Sleep(1300);
}

/* 4) 주석 줄만 추출 */
static void dev_extract_comments(LineBuffer *lb,const char *filename){
    FILE *f=fopen("comments_extracted.txt","a");
    if(!f){
        printf("[오류] 파일 생성 실패\n");
        Sleep(900);
        return;
    }

    fprintf(f,"===== Extracted from %s =====\n",filename);

    int cnt=0;
    for(int i=0;i<lb->count;i++){
        char *L=lb->lines[i];
        if(strstr(L,"//")||strstr(L,"/*")||strstr(L,"*/")){
            fprintf(f,"[%d] %s\n",i+1,L);
            cnt++;
        }
    }
    fprintf(f,"\n");
    fclose(f);

    printf("[완료] %d개 주석 줄 추출됨\n", cnt);
    Sleep(1100);
}

/* 5) 파일 저장 */
static void dev_save(LineBuffer *lb,const char *filename){
    char *o = string_from_lines(lb);
    if(write_whole_file(filename,o)==0)
        printf("[저장 완료] %s 업데이트됨!\n", filename);
    else
        printf("[오류] 저장 실패\n");

    free(o);
    Sleep(1100);
}

/* ===============================
   개발자 모드 루프
   =============================== */
static char *auto_format_content(const char *content) {
    size_t len = strlen(content);
    size_t cap = len * 2 + 1024;
    char *out = malloc(cap);
    if (!out) return NULL;

    size_t op = 0;
    int indent = 0, at_start = 1;

    for (size_t i = 0; i < len; i++) {
        char c = content[i];

        /* 줄 시작 시 들여쓰기 적용 */
        if (at_start) {
            while (content[i] == ' ' || content[i] == '\t' || content[i] == '\r')
                i++;

            if (content[i] == '}')
                if (indent > 0) indent--;

            for (int k = 0; k < indent; k++)
                out[op++] = ' ', out[op++] = ' ', out[op++] = ' ', out[op++] = ' ';

            at_start = 0;
        }

        if (c == '\t') {
            out[op++] = ' ', out[op++] = ' ', out[op++] = ' ', out[op++] = ' ';
        }
        else {
            out[op++] = c;
            if (c == '{') indent++;
            if (c == '\n') at_start = 1;
        }
    }

    out[op] = '\0';
    return out;
}

static void developer_mode(){
    char filename[256];
    printf("개발자 모드 — 파일 이름 입력: ");
    if(!fgets(filename,sizeof(filename),stdin)) return;
    filename[strcspn(filename,"\n")]='\0';

    if(file_size(filename)<0){
        printf("[오류] 파일 존재하지 않음\n");
        Sleep(900);
        return;
    }

    backup_file(filename);

    char *orig = read_whole_file(filename);
    char *fmt  = auto_format_content(orig);
    LineBuffer *lb = lines_from_string(fmt);

    /* formatted 파일 출력 */
    char temp[256];
    snprintf(temp,sizeof(temp),"%s.formatted",filename);
    write_whole_file(temp, fmt);

    printf("[자동포맷] %s.formatted 저장됨\n", temp);
    Sleep(800);

    int run=1;
    while(run){
        printf("\n[개발자 모드 - %s]\n", filename);
        printf("1) 주석 추가\n");
        printf("2) 자동 주석 처리\n");
        printf("3) 하이라이트 + 오타 감지\n");
        printf("4) 주석 추출\n");
        printf("5) 저장하고 종료\n");
        printf("6) 코드 보기\n");
        printf("0) 저장 없이 종료\n");
        printf("선택> ");

        char buf[16];
        fgets(buf,sizeof(buf),stdin);
        int sel = atoi(buf);

        switch(sel){
            case 1: dev_add_comment(lb); break;
            case 2: dev_auto_comment(lb); break;
            case 3: dev_highlight(lb, filename); break;
            case 4: dev_extract_comments(lb, filename); break;
            case 5: dev_save(lb, filename); run=0; break;
            case 6: dev_show_buffer(lb); break;
            case 0: printf("저장 없이 종료합니다.\n"); run=0; break;
            default: printf("잘못된 입력\n");
        }
    }

    free_lb(lb);
    free(orig);
    free(fmt);
}

/* ============================================================
   리뷰 모드
   ============================================================ */

static void review_show_all(LineBuffer *lb){
    printf("\n=== 전체 코드 ===\n\n");
    for(int i=0;i<lb->count;i++)
        print_line(lb->lines[i], i+1, PM_REVIEW, NULL);
    Sleep(1200);
}

static void review_show_range(LineBuffer *lb){
    char buf[64];
    printf("키워드 또는 엔터: ");
    fgets(buf,sizeof(buf),stdin);
    buf[strcspn(buf,"\n")]='\0';

    if(buf[0]){
        printf("\n=== '%s' 포함 줄 ===\n\n",buf);
        int hit=0;
        for(int i=0;i<lb->count;i++){
            if(strstr(lb->lines[i],buf)){
                print_line(lb->lines[i],i+1,PM_REVIEW,NULL);
                hit++;
            }
        }
        if(!hit) printf("[검색 결과 없음]\n");
        Sleep(1200);
        return;
    }

    char sline[16], eline[16];
    printf("시작 줄: "); fgets(sline,sizeof(sline),stdin);
    printf("끝 줄: ");   fgets(eline,sizeof(eline),stdin);
    int s=atoi(sline), e=atoi(eline);
    if(s<1)s=1; if(e>lb->count)e=lb->count;

    printf("\n=== %d~%d 줄 ===\n\n",s,e);
    for(int i=s-1;i<e;i++)
        print_line(lb->lines[i],i+1,PM_REVIEW,NULL);
    Sleep(1200);
}

static void review_add(const char *filename) {
    FILE *f = fopen("review_notes.txt", "r");
    char *temp_content = NULL;
    long size = 0;

    if (f) {
        fseek(f, 0, SEEK_END);
        size = ftell(f);
        fseek(f, 0, SEEK_SET);

        temp_content = malloc(size + 1);
        fread(temp_content, 1, size, f);
        temp_content[size] = '\0';
        fclose(f);
    }

    char header[256];
    snprintf(header, sizeof(header), "===== Review for %s =====", filename);

    char *new_content = malloc(size + 4096);
    new_content[0] = '\0';

    // 기존 섹션 제거
    if (temp_content) {
        char *p = temp_content;
        char *sec_start = strstr(p, header);

        while (sec_start) {
            // 이전 부분 붙이기
            strncat(new_content, p, sec_start - p);

            // 다음 섹션 찾기
            char *next = strstr(sec_start + 1, "===== Review for ");
            if (!next) break;

            p = next;
            sec_start = strstr(p, header);
        }

        if (sec_start == NULL)
            strcat(new_content, p);

        free(temp_content);
    }

    // 새로운 섹션 추가
    FILE *w = fopen("review_notes.txt", "w");
    fprintf(w, "%s", new_content);

    fprintf(w, "%s\n", header);

    char buf[512];
    while (1) {
        printf("줄번호:코멘트 입력 (엔터 종료)\n> ");
        if (!fgets(buf, sizeof(buf), stdin)) break;
        if (buf[0] == '\n') break;

        buf[strcspn(buf, "\n")] = '\0';

        char *colon = strchr(buf, ':');
        if (!colon) {
            fprintf(w, "%s\n", buf);
            continue;
        }

        *colon = '\0';
        int line_no = atoi(buf);
        char *comment = colon + 1;
        while (*comment == ' ') comment++;

        if (line_no > 0)
            fprintf(w, "[line %d] %s\n", line_no, comment);
        else
            fprintf(w, "%s\n", comment);
    }
    fprintf(w, "\n");
    fclose(w);
    free(new_content);

    printf("[리뷰] 저장됨\n");
    Sleep(900);
}

static void review_show_notes(){
    FILE *f=fopen("review_notes.txt","r");
    if(!f){
        printf("[리뷰] 리뷰 노트 없음\n"); Sleep(900);
        return;
    }

    printf("\n=== review_notes.txt ===\n\n");
    char buf[512];
    while(fgets(buf,sizeof(buf),f)) fputs(buf,stdout);
    fclose(f);

    Sleep(1200);
}

static void review_merge(LineBuffer *lb, const char *filename){
    FILE *f = fopen("review_notes.txt", "r");
    if (!f) {
        printf("[리뷰] review_notes.txt 없음\n");
        Sleep(900);
        return;
    }

    char *map[lb->count];
    memset(map, 0, sizeof(map));

    char line[512];
    int in_sec = 0;
    char header[256];
    snprintf(header, sizeof(header), "===== Review for %s =====", filename);

    while (fgets(line, sizeof(line), f)) {
        line[strcspn(line, "\n")] = '\0';

        if (!strncmp(line, "=====", 5)) {
            in_sec = (strcmp(line, header) == 0);
            continue;
        }
        if (!in_sec) continue;

        if (!strncmp(line, "[line ", 6)) {
            char *rb = strchr(line, ']');
            *rb = '\0';
            int ln = atoi(line + 6);
            char *cm = rb + 1;
            if (*cm == ' ') cm++;

            if (ln >= 1 && ln <= lb->count)
                map[ln - 1] = strdup(cm);
        }
    }
    fclose(f);

    printf("\n=== 코드 + 리뷰 코멘트 병합(삽입 스타일) ===\n\n");

    for (int i = 0; i < lb->count; i++) {
        print_line(lb->lines[i], i + 1, PM_REVIEW, NULL);

        if (map[i]) {
            printf("      %s// REVIEW: %s%s\n",
                C_COMMENT, map[i], C_RESET);
        }
    }

    Sleep(1500);
}

static void review_save(LineBuffer *lb,const char *filename){
    char *s=string_from_lines(lb);
    if(write_whole_file(filename,s)==0)
        printf("[저장 완료]\n");
    else
        printf("[오류] 저장 실패\n");

    free(s);
    Sleep(1000);
}

/* ===============================
   리뷰 모드 루프
   =============================== */
   static void review_apply_to_file(LineBuffer *lb, const char *filename) {
    int original_count = lb->count;

    /* 리뷰 내용을 저장할 배열 */
    char **map = calloc(original_count, sizeof(char*));
    if (!map) {
        printf("[오류] 메모리 부족\n");
        return;
    }

    FILE *f = fopen("review_notes.txt", "r");
    if (!f) {
        printf("[리뷰 적용 실패] review_notes.txt 없음\n");
        free(map);
        Sleep(900);
        return;
    }

    char buf[512];
    char head[256];
    snprintf(head, sizeof(head), "===== Review for %s =====", filename);

    int in_sec = 0;

    /* review_notes.txt 읽기 */
    while (fgets(buf, sizeof(buf), f)) {
        buf[strcspn(buf, "\n")] = '\0';

        if (!strncmp(buf, "=====", 5)) {
            in_sec = (strcmp(buf, head) == 0);
            continue;
        }
        if (!in_sec) continue;

        if (!strncmp(buf, "[line ", 6)) {
            char *rb = strchr(buf, ']');
            *rb = '\0';

            int ln = atoi(buf + 6);
            char *cm = rb + 1;
            if (*cm == ' ') cm++;

            if (ln >= 1 && ln <= original_count) {
                int idx = ln - 1;

                if (!map[idx]) map[idx] = strdup(cm);
                else {
                    char *tmp = malloc(strlen(map[idx]) + strlen(cm) + 4);
                    sprintf(tmp, "%s | %s", map[idx], cm);
                    free(map[idx]);
                    map[idx] = tmp;
                }
            }
        }
    }
    fclose(f);


    /* 리뷰 삽입 */
    for (int i = original_count - 1; i >= 0; i--) {
        if (map[i]) {
            char commentLine[512];
            snprintf(commentLine, sizeof(commentLine), "    // REVIEW: %s", map[i]);

            /* 줄 삽입 */
            lb->lines = realloc(lb->lines, sizeof(char*) * (lb->count + 1));
            memmove(&lb->lines[i + 2], &lb->lines[i + 1],
                    sizeof(char*) * (lb->count - i - 1));

            lb->lines[i + 1] = strdup(commentLine);
            lb->count++;
        }
    }

    /* 파일 저장 */
    char *out = string_from_lines(lb);
    if (write_whole_file(filename, out) == 0)
        printf("[저장 완료] 리뷰가 파일에 성공적으로 적용되었습니다!\n");
    else
        printf("[오류] 파일 저장 실패\n");

    free(out);

    /* free는 original_count까지만 */
    for (int i = 0; i < original_count; i++) {
        SAFE_FREE(map[i]);
    }
    free(map);

    Sleep(1100);
}



static void review_mode(){

    char filename[256];
    printf("리뷰 모드 — 파일 이름 입력: ");
    fgets(filename,sizeof(filename),stdin);
    filename[strcspn(filename,"\n")]='\0';
    if(!filename[0]) return;

    char *orig=read_whole_file(filename);
    if(!orig){
        printf("[오류] 파일 읽기 실패\n");
        Sleep(900);
        return;
    }

    backup_file(filename);


    char *fmt=auto_format_content(orig);
    LineBuffer *lb = lines_from_string(fmt);

    int run=1;
    while(run){
        printf("\n[리뷰 모드 - %s]\n",filename);
        printf("1) 전체 문서 보기\n");
        printf("2) 범위/키워드 보기\n");
        printf("3) 리뷰 코멘트 작성\n");
        printf("4) 리뷰 노트 보기\n");
        printf("5) 문서 + 리뷰 병합 보기\n");
        printf("6) 저장하고 종료\n");
        printf("0) 저장 없이 종료\n");
        printf("선택> ");

        char buf[16];
        fgets(buf,sizeof(buf),stdin);
        int sel=atoi(buf);

        switch(sel){
            case 1: review_show_all(lb); break;
            case 2: review_show_range(lb); break;
            case 3: review_add(filename); break;
            case 4: review_show_notes(); break;
            case 5: review_merge(lb,filename); break;
            case 6:
                    review_apply_to_file(lb, filename);
                    run = 0;
                    break;

            case 0: printf("[종료] 저장하지 않고 종료합니다.\n"); run=0; break;
            default: printf("[잘못된 입력]\n");
        }
    }

    free_lb(lb);
    free(orig);
    free(fmt);
}

/* ============================================================
   복구 모드
   ============================================================ */

   static void restore_mode() {
    char filename[256];
    printf("복구할 원본 파일 이름 입력 (예: test.txt): ");
    fgets(filename, sizeof(filename), stdin);
    filename[strcspn(filename, "\n")] = '\0';

    if (!filename[0]) {
        printf("[취소] 파일 이름이 비어있습니다.\n");
        Sleep(800);
        return;
    }

    // 백업 파일 이름 자동 생성
    char bak[256];
    snprintf(bak, sizeof(bak), "%s.bak", filename);

    // 백업 파일 존재 확인
    if (file_size(bak) < 0) {
        printf("\n[오류] '%s' 백업 파일이 존재하지 않습니다.\n", bak);

        // 추가: 디렉토리 내의 .bak 파일 목록을 보여줌
        printf("현재 폴더의 백업(.bak) 파일 목록:\n");
        system("dir *.bak");  // 리눅스면 "ls *.bak"

        Sleep(1500);
        return;
    }

    printf("\n%s → %s 로 복구하시겠습니까? (y/N): ", bak, filename);
    int c = getchar(); 
    while (getchar() != '\n');

    if (c != 'y' && c != 'Y') {
        printf("[취소] 복구 중단됨.\n");
        Sleep(800);
        return;
    }

    // 실제 복구 진행
    if (copy_file(bak, filename) == 0)
        printf("[완료] %s 가 성공적으로 복구되었습니다!\n", filename);
    else
        printf("[오류] 복구 실패\n");

    Sleep(1200);
}


/* ============================================================
   메인 메뉴
   ============================================================ */
int main(){
    setbuf(stdout,NULL);

    while(1){
        printf("\n============================================\n");
        printf("   시스템프로그래밍 기반 주석형 텍스트 에디터\n");
        printf("============================================\n");
        printf("1) 개발자 모드\n");
        printf("2) 리뷰 모드\n");
        printf("3) 복구 모드\n");
        printf("0) 종료\n");
        printf("선택> ");

        char buf[16];
        fgets(buf,sizeof(buf),stdin);
        int sel=atoi(buf);

        switch(sel){
            case 1: developer_mode(); break;
            case 2: review_mode(); break;
            case 3: restore_mode(); break;
            case 0:
                printf("프로그램 종료합니다.\n");
                Sleep(700);
                return 0;
            default:
                printf("[오류] 잘못된 입력\n");
        }
    }
}


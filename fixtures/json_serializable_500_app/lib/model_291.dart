import 'package:json_annotation/json_annotation.dart';

part 'model_291.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model291 {
  const Model291({required this.id, required this.value});

  final int id;
  final String value;

  factory Model291.fromJson(Map<String, dynamic> json) =>
      _$Model291FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model291ToJson(this);
}

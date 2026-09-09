import 'package:json_annotation/json_annotation.dart';

part 'model_161.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model161 {
  const Model161({required this.id, required this.value});

  final int id;
  final String value;

  factory Model161.fromJson(Map<String, dynamic> json) =>
      _$Model161FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model161ToJson(this);
}

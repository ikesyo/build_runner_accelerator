import 'package:json_annotation/json_annotation.dart';

part 'model_222.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model222 {
  const Model222({required this.id, required this.value});

  final int id;
  final String value;

  factory Model222.fromJson(Map<String, dynamic> json) =>
      _$Model222FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model222ToJson(this);
}

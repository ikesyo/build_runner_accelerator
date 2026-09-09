import 'package:json_annotation/json_annotation.dart';

part 'model_252.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model252 {
  const Model252({required this.id, required this.value});

  final int id;
  final String value;

  factory Model252.fromJson(Map<String, dynamic> json) =>
      _$Model252FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model252ToJson(this);
}

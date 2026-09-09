import 'package:json_annotation/json_annotation.dart';

part 'model_236.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model236 {
  const Model236({required this.id, required this.value});

  final int id;
  final String value;

  factory Model236.fromJson(Map<String, dynamic> json) =>
      _$Model236FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model236ToJson(this);
}

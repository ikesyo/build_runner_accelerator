import 'package:json_annotation/json_annotation.dart';

part 'model_365.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model365 {
  const Model365({required this.id, required this.value});

  final int id;
  final String value;

  factory Model365.fromJson(Map<String, dynamic> json) =>
      _$Model365FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model365ToJson(this);
}

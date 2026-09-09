import 'package:json_annotation/json_annotation.dart';

part 'model_362.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model362 {
  const Model362({required this.id, required this.value});

  final int id;
  final String value;

  factory Model362.fromJson(Map<String, dynamic> json) =>
      _$Model362FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model362ToJson(this);
}

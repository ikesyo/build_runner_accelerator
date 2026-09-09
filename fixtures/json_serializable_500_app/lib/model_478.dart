import 'package:json_annotation/json_annotation.dart';

part 'model_478.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model478 {
  const Model478({required this.id, required this.value});

  final int id;
  final String value;

  factory Model478.fromJson(Map<String, dynamic> json) =>
      _$Model478FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model478ToJson(this);
}

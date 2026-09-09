import 'package:json_annotation/json_annotation.dart';

part 'model_012.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model012 {
  const Model012({required this.id, required this.value});

  final int id;
  final String value;

  factory Model012.fromJson(Map<String, dynamic> json) =>
      _$Model012FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model012ToJson(this);
}
